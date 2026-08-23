# Spot

A fair, shared Spotify queue for parties.

- **Host** = this app on an Android phone (the one plugged into the speakers).
  It plays through the Spotify app on that phone, keeps running with the
  screen off, and shows a QR code.
- **Members** = friends who scan the QR with their phone camera. That opens the
  member web page, where they search Spotify and build a personal queue. No
  install, no Spotify account needed.
- **Fairness**: whenever a song ends, the next one is the head of the queue of
  whoever has had the **least airtime** so far. Sitting out doesn't bank time:
  only people with songs queued (or playing) are party members; anyone whose
  queue runs dry is dropped and re-admitted at the party's maximum airtime
  when they next add a song — back of the line, not "catching up".
- **Veto with your own time**: any member can skip the playing song; the
  remaining time is charged to the *skipper's* airtime (kept as a debt and
  applied on their next queued song if they have nothing queued), while the
  song's owner only paid for what was heard.
- **Listeners**: everyone whose page has talked to the host recently gets
  state pushes (member pages ping every 4 min while visible); after 10 silent
  minutes the host stops pushing to them, and they get a fresh snapshot the
  moment they come back.
- **Playlists**: members can't log in to Spotify themselves (Development Mode
  allows only 5 authenticated users), but they can paste any Spotify link —
  song, playlist, album (Share → Copy link in the Spotify app) — and Spot lists
  its tracks to add. Installed to the Home Screen (Android), Spot is a Web
  Share Target, so it appears in Spotify's Share menu directly. Private and
  Spotify-curated playlists can't be read with the host token.

Communication runs through the [fcm-switch](https://github.com/zond/analfapet/tree/main/functions)
relay (FCM push + inbox pull) — the same Cloud Functions analfapet uses.

## Architecture

```
 member phone (web, gh-pages)            host phone (Android app)
 ┌──────────────────────────┐            ┌───────────────────────────┐
 │ search Spotify ──────────┼─ token ───▶│ Spotify Web API (PKCE)    │
 │ (host token)             │            │ SpotifyAuth: refresh 1h   │
 │ enqueue / dequeue ───────┼─ Send ────▶│ HostController            │
 │ state ◀──────────────────┼─ Send ─────┤   Party (least airtime)   │
 │ (FCM push + Inbox poll)  │            │   App Remote → Spotify app│
 └──────────────────────────┘            │   foreground service      │
                                         └───────────────────────────┘
                    fcm-switch: Register / Send / Inbox
```

One Flutter codebase: Android builds are the host, web builds are the member
page (`lib/main.dart` switches on platform; `lib/host/` and `lib/member/` are
conditionally imported so each side only compiles its own platform code).

| Path | What |
|---|---|
| `lib/models/` | `Track`, `Party` (+ fairness policy), `MemberView` (snapshot sent to members) |
| `lib/services/` | `Identity`, `SwitchClient` (fcm-switch), `Message` envelope, `SpotifyWebApi` |
| `lib/host/` | `SpotifyAuth` (PKCE + refresh), `AppRemotePlayer`, `HostController`, foreground service, push, UI |
| `lib/member/` | `MemberController`, web push (FCM compat SDK via JS interop), QR scanner, UI |
| `web/` | index.html (Firebase compat + QR helpers), service worker, manifest |
| `test/party_test.dart` | Fairness policy tests |

### Protocol (over fcm-switch)

Every message is `{t: type, id: uuid, m: json}`. Receivers de-duplicate on
`id` because a message can arrive both by push and by inbox.

| Direction | `t` | body |
|---|---|---|
| member → host | `join` | `{uuid, name}` — also means "send me the state" |
| member → host | `enqueue` | `{uuid, item: {id, t: Track}}` |
| member → host | `dequeue` | `{uuid, itemId}` |
| host → member | `state` | full personal snapshot: host token + expiry, now playing (+ position/time for extrapolation), my queue & airtime, everyone else's name/airtime/queue length/next |

Every `state` is a complete snapshot, so one message is enough to be in sync.

### Playback model

The host plays one track at a time via App Remote and watches player-state
events: airtime is credited as the position advances, the end of a track is
detected from "paused at 0 / at the end", "Spotify moved to another track", or
"position jumped back after the end"; a timer re-checks shortly after the
expected end in case no event arrives. Then `Party.takeNext()` picks the next
member/track.

## Setup

### 1. Spotify app (dashboard)

1. <https://developer.spotify.com/dashboard> → Create app. Note the **Client ID**.
2. Redirect URI: `spot://callback`
3. Android packages: package name `com.zond.spot`, SHA-1 of your signing key
   (`keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android | grep SHA1`
   for the debug key).
4. The host's Spotify account must be **Premium** (not Mini/Lite). Only the host
   ever logs in to Spotify, so the app can stay in development mode.

### 2. Firebase (host push) — done

The host needs an FCM token to be addressable by fcm-switch. The Android app
`com.zond.spot` ("Spot host") is registered in the `fcm-switch` Firebase
project and its options are in `lib/firebase_options.dart`. (If it is ever
re-registered: `flutterfire configure --project=fcm-switch --platforms=android`.)
The member web page reuses the fcm-switch web app config in `web/index.html`
and the service worker.

### 3. Build & install the host app

```bash
flutter build apk --release      # → build/app/outputs/flutter-apk/app-release.apk
cp build/app/outputs/flutter-apk/app-release.apk ~/Drive/Spot/Spot.apk   # shared Drive folder
# or straight to a connected phone:
flutter run -d <your-phone>
```

The Spotify client id is entered on the setup screen (stored on the phone), so
the APK is generic; `--dart-define=SPOTIFY_CLIENT_ID=...` only sets a default.

On the phone: Spotify app installed and logged in → open Spot → client id + name
→ *Log in* (Spotify consent in a browser tab; this also grants
`app-remote-control`, which is what lets the Spotify app accept our App Remote
connection without showing its own dialog — Android blocks that dialog as a
background activity launch and the connect would hang) → *Start party*. Android will ask for
notification permission and to ignore battery optimisation: accept both, they
keep the party alive with the screen off. First connect, the Spotify app shows
an App Remote consent dialog.

### 4. Deploy the member web app

```bash
./deploy-web.sh          # builds and force-pushes gh-pages of zond/spot
```

Served from `https://zond.github.io/spot/` (the `Config.webBaseUrl` the QR
codes point to).

## Installing the member page (optional, recommended)

The member page works as a plain tab, but installed to the home screen it is
nicer: notifications (how the host reaches you) are more reliable, Spotify's
Share menu gets a "Spot" entry for sending playlists/songs, and it opens like
an app. The page offers it itself on phones:

- **Android Chrome**: tap the "Install Spot on your home screen" line on the
  join/party screen (or Chrome menu ⋮ → *Add to Home screen* / *Install app*).
- **iPhone/iPad**: Safari Share (square with arrow) → *Add to Home Screen*,
  then open Spot from the home screen — on iOS web push only works that way.

Installed or not, the page remembers the last host, so next time it just
rejoins; scanning a new host's QR switches party.

## Joining (members)

Scan the host QR with the phone camera → page opens → enter a name → *Join* →
allow notifications (that is how the host talks to you). On iPhone, web push
only works from the Home Screen: add the page to the Home Screen first, then
open it from there and join. Android Chrome works directly.

## Known limits / ideas

- The host app is a sideloaded APK (no Play Store).
- Members hold the host's access token (≤1 h, refreshed) — fine among friends;
  a relay-through-host search mode would avoid even that.
- A ~1–2 s gap between songs; queueing the next track into Spotify shortly
  before the end would make it gapless.

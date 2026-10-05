# Claude Code Project Guide

## What this is

One Flutter codebase, two apps: **Android = party host** (plays through the
Spotify app via App Remote, fair scheduler, foreground service, QR code),
**web = member page** (search with the host's token, personal queue), hosted on
gh-pages. They talk through the fcm-switch relay (`zond/analfapet/functions`,
already deployed at `europe-west1-fcm-switch.cloudfunctions.net`).

## Build / deploy / push

- Host: `flutter build apk --release` and copy `app-release.apk` to
  `~/Drive/Spot/Spot.apk` (the user's Google Drive mount; the `Spot` folder is
  shared with their family, who install from there). Use a plain
  `cp <apk> ~/Drive/Spot/Spot.apk` straight to the final name, in the
  background with a long timeout since the mount is slow. Never copy to a
  temp name and rename: Drive types the file from the name it is *created*
  with, so `Spot.apk.part` + `mv` leaves it as `application/x-zip`, which
  Android's package installer refuses ("uninstallable"), and a later mimeType
  PATCH is ignored. `flutter run -d <phone>` for dev.
- Member web: `./deploy-web.sh` builds and force-pushes `gh-pages` of
  `git@github.com:zond/spot.git`. Fix build errors rather than skipping.
- Source: `git add` / `git commit` / `git push origin main`.
- Checks: `flutter analyze`, `flutter test` (fairness tests in `test/`).

## Layout

- `lib/main.dart` — platform switch with conditional imports (`host/` only on
  io, `member/` only on web). Keep web-only code (`package:web`, `dart:ui_web`,
  JS interop) under `lib/member/`, Android-only plugins under `lib/host/`.
- `lib/models/` — `Track`, `Party` (state + least-airtime policy; queue entries are
  songs or `PlaylistRef`s, per-member shuffle/repeat/cursor; `plan`/`commit` are
  pure, the host resolves playlist entries via the Web API), `MemberView`.
- `lib/services/` — `Identity`, `SwitchClient`, `Message`/`SeenIds`, `SpotifyWebApi`,
  `SpotifyPublicPage` (embed-page scrape for the length of playlists the API
  withholds; host-only, browsers get no CORS headers there).
- `lib/host/` — `SpotifyAuth` (PKCE), `AppRemotePlayer`, `HostController`,
  `HostForeground`, `HostPush`, `host_app.dart` (screens).
- `lib/member/` — `MemberController`, `WebPush`, `QrScannerScreen`, `member_app.dart`.
- `lib/widgets/` — pieces both apps show, e.g. `HistoryList` (what played, and
  how each song ended).
- `web/index.html` — Firebase compat init + `_spotGetToken` / `_spotOnMessage`
  / `_spotDetectQR` JS helpers used from Dart.

## Conventions / decisions

- One way to play a playlist entry, whoever owns it: `_playlistCatalogue`
  reads the whole song list from the *public page* (one source, so the path is
  exercised at every party), falling back to the Web API only for playlists
  the page can't show — a private one of the host's — and for the tail beyond
  its hundred-song limit. `_fromPlaylist` picks from that list by position.
  A position that no longer exists (the playlist shrank since it was read)
  shows up as a song that won't start: the stored copy is dropped and the
  turn moves on, so the next read is fresh. There
  is no separate "play the context by index" path any more: it was rarely
  trodden and therefore the buggy one (new contexts moving playback, no
  queue-ahead). Cost: a hidden playlist beyond the public page's hundred-song
  cap only offers its first hundred songs.

- An app update must not pause playback: `_teardown` only pauses when the
  host deliberately ends the party (`stop`), because a paused speaker drops
  its Spotify session and the party then comes back on the phone. The device
  the party was on is also remembered across restarts
  (`HostSettings.rememberDevice`).

- Keeping a cast alive: a Connect session dies in the gaps when nothing
  plays, so the next song is started `Config.handoverLead` *before* the
  current one ends — the command lands while music is still playing and the
  speaker never falls idle. Playlist entries hand over as "item n of the
  playlist" (`skipToIndex`, or `context_uri` + offset on Connect), which keeps
  Spotify inside the playlist's own context instead of opening a new one. The
  host logs how long each handover took ("handover took N ms"); that is the
  number `handoverLead` should be tuned against.

- Playback transport: App Remote by default — it continues wherever the
  Spotify app is already playing, casting included, and asks no questions
  about devices. The Web API is used only when the host has *pinned* a
  speaker, or as a fallback when the app won't play. Naming a device means
  trusting `GET /me/player`, and that can report the phone while the sound is
  actually coming out of a speaker; saying so then moves the music to the
  phone (seen in the field). Restricted devices (Sonos) reject Web API
  commands outright anyway.

- `Config.spotifyScopes` must include `app-remote-control`: the Spotify app's own
  App Remote consent activity is blocked by Android (BAL) while Spot is in front,
  so the permission has to be pre-granted through the PKCE login. `SpotifyAuth`
  stores the granted scope set and `needsRelogin` forces a re-login when it changes.

- Release builds need `android/app/proguard-rules.pro` (`-keep class com.spotify.** { *; }`):
  App Remote finds the Spotify app via reflection and R8 otherwise strips the
  locator's constructor, so release APKs claim Spotify isn't installed.

- fcm-switch is used as-is (no server changes): everyone registers with a real
  FCM token; members therefore need notification permission to join.
- Delivery is at-least-once (push + inbox); every receiver de-dups on message `id`.
- Every message carries `v` = `Config.protocolVersion`; bump it when host and
  member must match (member reloads itself on a newer host, host shows an
  "update from Drive/Spot" banner on a newer member).
- Every host→member message is a full personal snapshot (`MemberView`).
- Fairness = least airtime first; airtime credited from actual playback
  position deltas. `Party` keeps *members* (something queued or playing) apart
  from *listeners* (anyone heard from; push recipients for
  `Config.listenerTimeout`). Idle members are dropped (`removeIdle`) and
  re-admitted at the party maximum on their next enqueue; member pages ping
  every `Config.memberPingInterval` while visible.
- Spotify Development Mode (Feb 2026): search ≤ 10 results, 5 auth users,
  no /users/{id}/playlists or batch endpoints; playlist items readable only
  for playlists the host owns or collaborates on — others answer 403 *or* an
  empty page, and `GET /playlists/{id}` omits the whole `items` object, so the
  length is hidden too. Such playlists are played by index through the Spotify
  app; members ask the host (`MsgType.playlistMeta`) for name/length. Member playlist access is via
  pasted/shared links (`SpotifyLink`, `/playlists/{id}/items`, `/albums/{id}`,
  `/tracks/{id}`) and the manifest's `share_target`.
- Spotify client id is entered in the app (`HostSettings`, SharedPreferences);
  `--dart-define=SPOTIFY_CLIENT_ID` is only a default. Never commit one.
- `lib/firebase_options.dart` holds the real fcm-switch Android app
  (com.zond.spot, registered 2026-08-22) + web options.

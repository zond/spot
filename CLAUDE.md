# Claude Code Project Guide

## What this is

One Flutter codebase, two apps: **Android = party host** (plays through the
Spotify app via App Remote, fair scheduler, foreground service, QR code),
**web = member page** (search with the host's token, personal queue), hosted on
gh-pages. They talk through the fcm-switch relay (`zond/analfapet/functions`,
already deployed at `europe-west1-fcm-switch.cloudfunctions.net`).

## Build / deploy / push

- Host: `flutter build apk --release` and copy `app-release.apk` to `~/Drive/Spot.apk`
  (the user's Google Drive mount; they install from there). `flutter run -d <phone>` for dev.
- Member web: `./deploy-web.sh` builds and force-pushes `gh-pages` of
  `git@github.com:zond/spot.git`. Fix build errors rather than skipping.
- Source: `git add` / `git commit` / `git push origin main`.
- Checks: `flutter analyze`, `flutter test` (fairness tests in `test/`).

## Layout

- `lib/main.dart` — platform switch with conditional imports (`host/` only on
  io, `member/` only on web). Keep web-only code (`package:web`, `dart:ui_web`,
  JS interop) under `lib/member/`, Android-only plugins under `lib/host/`.
- `lib/models/` — `Track`, `Party` (state + least-airtime policy), `MemberView`.
- `lib/services/` — `Identity`, `SwitchClient`, `Message`/`SeenIds`, `SpotifyWebApi`.
- `lib/host/` — `SpotifyAuth` (PKCE), `AppRemotePlayer`, `HostController`,
  `HostForeground`, `HostPush`, `host_app.dart` (screens).
- `lib/member/` — `MemberController`, `WebPush`, `QrScannerScreen`, `member_app.dart`.
- `web/index.html` — Firebase compat init + `_spotGetToken` / `_spotOnMessage`
  / `_spotDetectQR` JS helpers used from Dart.

## Conventions / decisions

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
- Every host→member message is a full personal snapshot (`MemberView`).
- Fairness = least airtime first; airtime credited from actual playback
  position deltas; idle members (empty queue) follow the party maximum and
  late joiners start there (no banking credit while sitting out).
- Spotify Development Mode (Feb 2026): search ≤ 10 results, 5 auth users,
  no /users/{id}/playlists or batch endpoints. Member playlist access is via
  pasted/shared links (`SpotifyLink`, `/playlists/{id}/items`, `/albums/{id}`,
  `/tracks/{id}`) and the manifest's `share_target`.
- Spotify client id is entered in the app (`HostSettings`, SharedPreferences);
  `--dart-define=SPOTIFY_CLIENT_ID` is only a default. Never commit one.
- `lib/firebase_options.dart` holds the real fcm-switch Android app
  (com.zond.spot, registered 2026-08-22) + web options.

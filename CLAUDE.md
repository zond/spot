# Claude Code Project Guide

## What this is

One Flutter codebase, two apps: **Android = party host** (plays through the
Spotify app via App Remote, fair scheduler, foreground service, QR code),
**web = member page** (search with the host's token, personal queue), hosted on
gh-pages. They talk through the fcm-switch relay (`zond/analfapet/functions`,
already deployed at `europe-west1-fcm-switch.cloudfunctions.net`).

## Build / deploy / push

- Host: `flutter run -d <phone> --dart-define=SPOTIFY_CLIENT_ID=...`
  (`flutter build apk --release --dart-define=...` + `flutter install` for an APK).
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

- fcm-switch is used as-is (no server changes): everyone registers with a real
  FCM token; members therefore need notification permission to join.
- Delivery is at-least-once (push + inbox); every receiver de-dups on message `id`.
- Every host→member message is a full personal snapshot (`MemberView`).
- Fairness = least airtime first; airtime credited from actual playback
  position deltas; late joiners start at the party minimum.
- Spotify client id is a `--dart-define` (`Config.spotifyClientId`), never committed.
- `lib/firebase_options.dart` is a placeholder until `flutterfire configure
  --project=fcm-switch --platforms=android` is run (host push needs it).

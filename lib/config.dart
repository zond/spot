/// Deployment configuration shared by the host app (Android) and the member
/// web app.
abstract final class Config {
  /// Base URL of the fcm-switch Cloud Functions (Register / Send / Inbox).
  static const functionsBase =
      'https://europe-west1-fcm-switch.cloudfunctions.net';

  /// Where the member web app is hosted. Join QR codes point here.
  static const webBaseUrl = 'https://zond.github.io/spot/';

  /// Spotify app client id (host only). Supplied at build time:
  ///   flutter run --dart-define=SPOTIFY_CLIENT_ID=...
  static const spotifyClientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');

  /// Redirect URI registered in the Spotify dashboard. Used both for the
  /// PKCE login (handled by flutter_web_auth_2's CallbackActivity) and for the
  /// App Remote connection.
  static const spotifyRedirectUri = 'spot://callback';
  static const spotifyRedirectScheme = 'spot';

  /// Scopes for the host token. Members only need search, which needs none;
  /// the playback scopes keep the Web API usable as a fallback controller.
  static const spotifyScopes =
      'user-read-playback-state user-modify-playback-state';

  /// FCM web push VAPID key of the fcm-switch Firebase project.
  static const vapidKey =
      'BADlJWLuNnXTe6VG4fCEhz-NdXSh5zElySUYFcJoOSRO8Hzs8MDNM_mN1FGb8TJvEZ5T26bKHA_f5irGG74m0tU';

  /// How often host and members pull their fcm-switch inbox (push is the fast
  /// path; this is the guarantee).
  static const inboxPollInterval = Duration(seconds: 2);

  /// Refresh the Spotify token this long before it expires.
  static const tokenRefreshMargin = Duration(minutes: 5);

  /// Host re-sends state to members at least this often (clock re-sync).
  static const stateHeartbeat = Duration(seconds: 20);
}

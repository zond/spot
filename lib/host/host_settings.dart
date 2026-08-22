import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Host-side settings that must survive without a rebuild, so one generic APK
/// can be installed from Drive and configured on the phone.
abstract final class HostSettings {
  static const _kClientId = 'spotify_client_id';

  /// Spotify client id: value entered in the app, else the build-time
  /// `--dart-define=SPOTIFY_CLIENT_ID` default.
  static String clientId = Config.spotifyClientId;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kClientId)?.trim();
    if (saved != null && saved.isNotEmpty) clientId = saved;
  }

  static Future<void> setClientId(String id) async {
    clientId = id.trim();
    final prefs = await SharedPreferences.getInstance();
    if (clientId.isEmpty) {
      await prefs.remove(_kClientId);
      clientId = Config.spotifyClientId;
    } else {
      await prefs.setString(_kClientId, clientId);
    }
  }
}

import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Host-side settings that must survive without a rebuild, so one generic APK
/// can be installed from Drive and configured on the phone.
abstract final class HostSettings {
  static const _kClientId = 'spotify_client_id';
  static const _kDeviceId = 'spotify_device_id';
  static const _kDeviceName = 'spotify_device_name';

  /// Spotify client id: value entered in the app, else the build-time
  /// `--dart-define=SPOTIFY_CLIENT_ID` default.
  static String clientId = Config.spotifyClientId;

  /// The Spotify Connect device the party is pinned to, if the host picked
  /// one. Null means "follow whatever Spotify is playing on".
  static String? deviceId;
  static String? deviceName;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kClientId)?.trim();
    if (saved != null && saved.isNotEmpty) clientId = saved;
    deviceId = prefs.getString(_kDeviceId);
    deviceName = prefs.getString(_kDeviceName);
  }

  static Future<void> setDevice(String? id, String? name) async {
    deviceId = id;
    deviceName = name;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_kDeviceId);
      await prefs.remove(_kDeviceName);
    } else {
      await prefs.setString(_kDeviceId, id);
      await prefs.setString(_kDeviceName, name ?? id);
    }
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

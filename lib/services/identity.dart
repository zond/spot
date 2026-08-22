import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Persistent per-device identity for the fcm-switch relay: a UUID (public,
/// used as the address) and a secret (authorises inbox reads), plus a display
/// name.
class Identity {
  static const _uuidKey = 'identity_uuid';
  static const _secretKey = 'identity_secret';
  static const _nameKey = 'identity_name';

  late final String uuid;
  late final String secret;
  String? _name;

  String? get name => _name;
  bool get hasName => _name != null && _name!.trim().isNotEmpty;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    uuid = prefs.getString(_uuidKey) ?? await _generate(prefs, _uuidKey);
    secret = prefs.getString(_secretKey) ?? await _generate(prefs, _secretKey);
    _name = prefs.getString(_nameKey);
  }

  Future<void> setName(String name) async {
    _name = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, _name!);
  }

  Future<String> _generate(SharedPreferences prefs, String key) async {
    final id = const Uuid().v4();
    await prefs.setString(key, id);
    return id;
  }
}

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'host_settings.dart';

class SpotifyAuthException implements Exception {
  SpotifyAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Spotify login for the host: Authorization Code + PKCE (no client secret),
/// with silent refresh so the token handed to members stays valid all night.
class SpotifyAuth extends ChangeNotifier {
  static const _kAccess = 'spotify_access_token';
  static const _kRefresh = 'spotify_refresh_token';
  static const _kExpires = 'spotify_expires_at';
  static const _kScopes = 'spotify_scopes';

  String? _access;
  String? _refresh;
  DateTime? _expiresAt;
  String? _scopes;

  /// True when logged in with an older scope set: log out and in again.
  bool get needsRelogin => isLoggedIn && _scopes != Config.spotifyScopes;

  String? get accessToken => _access;
  DateTime? get expiresAt => _expiresAt;
  bool get isLoggedIn => _refresh != null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _access = prefs.getString(_kAccess);
    _refresh = prefs.getString(_kRefresh);
    final exp = prefs.getInt(_kExpires);
    _expiresAt = exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp);
    _scopes = prefs.getString(_kScopes);
    notifyListeners();
  }

  /// Opens the Spotify consent page in a custom tab and exchanges the code.
  Future<void> login() async {
    if (HostSettings.clientId.isEmpty) {
      throw SpotifyAuthException('Enter your Spotify client id first');
    }
    final verifier = _randomString(64);
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final state = _randomString(16);
    final url = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': HostSettings.clientId,
      'response_type': 'code',
      'redirect_uri': Config.spotifyRedirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'scope': Config.spotifyScopes,
      'state': state,
    });
    final result = await FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: Config.spotifyRedirectScheme,
    );
    final params = Uri.parse(result).queryParameters;
    if (params['state'] != state) {
      throw SpotifyAuthException('Login state mismatch');
    }
    if (params['error'] != null) {
      throw SpotifyAuthException('Spotify login failed: ${params['error']}');
    }
    final code = params['code'];
    if (code == null) throw SpotifyAuthException('No code in redirect');
    await _tokenRequest({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': Config.spotifyRedirectUri,
      'client_id': HostSettings.clientId,
      'code_verifier': verifier,
    });
    _scopes = Config.spotifyScopes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kScopes, _scopes!);
    notifyListeners();
  }

  /// A token valid for at least [margin], refreshing if necessary. Null when
  /// not logged in.
  Future<String?> validToken(
      {Duration margin = Config.tokenRefreshMargin}) async {
    if (_access != null &&
        _expiresAt != null &&
        _expiresAt!.isAfter(DateTime.now().add(margin))) {
      return _access;
    }
    if (_refresh == null) return null;
    await refresh();
    return _access;
  }

  Future<void> refresh() async {
    final r = _refresh;
    if (r == null) throw SpotifyAuthException('Not logged in to Spotify');
    await _tokenRequest({
      'grant_type': 'refresh_token',
      'refresh_token': r,
      'client_id': HostSettings.clientId,
    });
  }

  Future<void> _tokenRequest(Map<String, String> form) async {
    final resp = await http
        .post(
          Uri.https('accounts.spotify.com', '/api/token'),
          headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
          body: form,
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      if (form['grant_type'] == 'refresh_token' &&
          resp.statusCode == 400 &&
          resp.body.contains('invalid_grant')) {
        // Refresh token revoked: force a fresh login.
        await logout();
      }
      throw SpotifyAuthException(
          'Spotify token request failed: ${resp.statusCode} ${resp.body}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    _access = j['access_token'] as String;
    _expiresAt = DateTime.now()
        .add(Duration(seconds: (j['expires_in'] as num? ?? 3600).toInt()));
    if (j['refresh_token'] is String) _refresh = j['refresh_token'] as String;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccess, _access!);
    await prefs.setString(_kRefresh, _refresh!);
    await prefs.setInt(_kExpires, _expiresAt!.millisecondsSinceEpoch);
    notifyListeners();
  }

  Future<void> logout() async {
    _access = null;
    _refresh = null;
    _expiresAt = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccess);
    await prefs.remove(_kRefresh);
    await prefs.remove(_kExpires);
    await prefs.remove(_kScopes);
    _scopes = null;
    notifyListeners();
  }

  static String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)])
        .join();
  }
}

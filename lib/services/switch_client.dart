import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class SwitchException implements Exception {
  SwitchException(this.op, this.status, this.body);
  final String op;
  final int status;
  final String body;
  @override
  String toString() => '$op failed: $status ${body.trim()}';
}

/// Client for the fcm-switch relay (Register / Send / Inbox Cloud Functions).
///
/// Semantics: a message to [targetUuid] is pushed over FCM when the target has
/// a token and always appended to the target's inbox, which the target drains
/// with [inbox]. Delivery is therefore at-least-once; consumers de-duplicate
/// on message id.
class SwitchClient {
  SwitchClient({http.Client? client, this.base = Config.functionsBase})
    : _http = client ?? http.Client(),
      _ownsClient = client == null;

  http.Client _http;
  final bool _ownsClient;
  final String base;

  Future<void> register({
    required String uuid,
    required String token,
    required String secret,
  }) async {
    final resp = await _post('Register', {
      'uuid': uuid,
      'token': token,
      'secret': secret,
    });
    if (resp.statusCode != 200) {
      throw SwitchException('Register', resp.statusCode, resp.body);
    }
  }

  /// Returns true if the message was pushed over FCM (false: inbox only).
  Future<bool> send(String targetUuid, Map<String, String> data) async {
    final resp = await _post('Send', {'targetUuid': targetUuid, 'data': data});
    if (resp.statusCode != 200) {
      throw SwitchException('Send', resp.statusCode, resp.body);
    }
    final body = jsonDecode(resp.body);
    return body is Map && body['pushed'] == true;
  }

  /// Drains and returns pending messages, oldest first.
  Future<List<Map<String, dynamic>>> inbox({
    required String uuid,
    required String secret,
  }) async {
    final resp = await _post('Inbox', {'uuid': uuid, 'secret': secret});
    if (resp.statusCode != 200) {
      throw SwitchException('Inbox', resp.statusCode, resp.body);
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final messages = body['messages'] as List? ?? const [];
    return messages.cast<Map<String, dynamic>>();
  }

  Future<http.Response> _post(String fn, Object body) async {
    try {
      return await _http
          .post(
            Uri.parse('$base/$fn'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
    } on http.ClientException {
      // Phones hop between Wi-Fi and mobile data; a pooled keep-alive socket
      // then dies with "Software caused connection abort". Drop the pool so
      // the next call opens a fresh connection.
      if (_ownsClient) {
        _http.close();
        _http = http.Client();
      }
      rethrow;
    }
  }
}

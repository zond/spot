import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../config.dart';

@JS('_spotGetToken')
external JSPromise<JSString?> _jsGetToken(
    web.ServiceWorkerRegistration reg, JSString vapidKey);

@JS('_spotOnMessage')
external set _jsOnMessage(JSFunction? f);

/// FCM web push for members, through the Firebase compat JS SDK loaded in
/// index.html (same pattern as analfapet). A member must hold a push token to
/// register with fcm-switch, so joining requires notification permission.
class WebPush {
  web.ServiceWorkerRegistration? _registration;
  String? token;
  String? error;

  /// Browser notification permission: granted / denied / default / unsupported.
  String get permission {
    try {
      return web.Notification.permission;
    } catch (_) {
      return 'unsupported';
    }
  }

  /// Registers the service worker (no permission needed).
  Future<void> init() async {
    if (_registration != null) return;
    try {
      final baseHref =
          web.document.querySelector('base')?.getAttribute('href') ?? '/';
      await web.window.navigator.serviceWorker
          .register(
            '${baseHref}firebase-messaging-sw.js'.toJS,
            web.RegistrationOptions(updateViaCache: 'none'),
          )
          .toDart;
      _registration = await web.window.navigator.serviceWorker.ready.toDart;
    } catch (e) {
      error = 'Service worker: $e';
    }
  }

  /// Asks for notification permission (call from a tap) and returns the FCM
  /// token, or null if permission was refused / push is unavailable.
  Future<String?> requestToken() async {
    await init();
    final reg = _registration;
    if (reg == null) return null;
    try {
      final perm = (await web.Notification.requestPermission().toDart).toDart;
      if (perm != 'granted') {
        error = 'Notification permission: $perm';
        return null;
      }
      final t = await _jsGetToken(reg, Config.vapidKey.toJS).toDart;
      token = t?.toDart;
      if (token == null) error = 'No push token';
      return token;
    } catch (e) {
      error = 'Push token: $e';
      return null;
    }
  }

  /// Foreground messages (page visible) arrive here as the FCM data map.
  void onMessage(void Function(Map<String, dynamic> data) handler) {
    _jsOnMessage = ((JSString json) {
      try {
        final decoded = jsonDecode(json.toDart);
        if (decoded is Map<String, dynamic>) handler(decoded);
      } catch (_) {}
    }).toJS;
  }
}

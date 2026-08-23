import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../firebase_options.dart';

/// FCM on the Android host. The token is what lets fcm-switch address this
/// device; foreground pushes give instant delivery of member messages, and the
/// inbox poll in the controller is the delivery guarantee.
class HostPush {
  String? token;
  String? error;
  void Function(String token)? onTokenRefresh;

  Future<String?> init(void Function(Map<String, dynamic> data) onData) async {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      final messaging = FirebaseMessaging.instance;
      try {
        await messaging.requestPermission();
      } catch (_) {
        // Data messages don't need notification permission; ignore.
      }
      token = await messaging.getToken();
      FirebaseMessaging.onMessage.listen((msg) => onData(msg.data));
      messaging.onTokenRefresh.listen((t) {
        token = t;
        onTokenRefresh?.call(t);
      });
      if (token == null) error = 'FCM returned no token';
    } catch (e) {
      error = '$e';
    }
    return token;
  }
}

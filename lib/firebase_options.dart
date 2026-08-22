// Placeholder. Generate the real file for the Android host with:
//
//   dart pub global activate flutterfire_cli
//   flutterfire configure --project=fcm-switch --platforms=android
//
// which registers the com.zond.spot Android app in the fcm-switch Firebase
// project and overwrites this file. The member web app does not use this
// (its push setup lives in web/index.html and web/firebase-messaging-sw.js).
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => throw UnsupportedError(
        'Firebase is not configured for this platform yet. Run '
        '`flutterfire configure --project=fcm-switch --platforms=android` '
        '(see README).',
      );
}

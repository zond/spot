// Firebase options for the fcm-switch project.
//
// Android: the "Spot host" app (package com.zond.spot) registered in the
// fcm-switch Firebase project on 2026-08-22 via the Firebase Management API —
// equivalent to `flutterfire configure --project=fcm-switch --platforms=android`.
// Re-run that command if the app is ever re-registered.
//
// The member web app does not use this file: its push setup lives in
// web/index.html and web/firebase-messaging-sw.js (same project, web app).
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for $defaultTargetPlatform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyA1sKy0bjTDuMzjOdXVEe3yH84J7Cw3E9o',
    appId: '1:245672555479:android:76162543b43420754e9192',
    messagingSenderId: '245672555479',
    projectId: 'fcm-switch',
    databaseURL:
        'https://fcm-switch-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'fcm-switch.firebasestorage.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyDdsNrnheLnhAe5fPJNkQo86f40DgBdg5I',
    appId: '1:245672555479:web:01dd2824ac0ff9e94e9192',
    messagingSenderId: '245672555479',
    projectId: 'fcm-switch',
    authDomain: 'fcm-switch.firebaseapp.com',
    databaseURL:
        'https://fcm-switch-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'fcm-switch.firebasestorage.app',
  );
}

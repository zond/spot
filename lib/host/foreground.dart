import 'package:flutter/material.dart' show Color;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the host process alive with the screen off.
///
/// The scheduler runs in the main Dart isolate; the foreground service (with
/// its persistent notification and wake lock) only stops Android from freezing
/// or killing the process. No work happens in the service isolate.
abstract final class HostForeground {
  static bool _initialized = false;
  static const _title = 'Spot is hosting';

  /// Our own status-bar glyph (white queue figures), declared in the manifest.
  static const _icon = NotificationIcon(
    metaDataName: 'com.zond.spot.service.NOTIFICATION_ICON',
    backgroundColor: Color(0xFF1DB954),
  );

  static void init() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'spot_host',
        channelName: 'Spot party',
        channelDescription: 'Keeps the party playing while the screen is off',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Notification permission (Android 13+) and battery-optimisation exemption,
  /// both needed for a long-lived foreground service.
  static Future<void> requestPermissions() async {
    final np = await FlutterForegroundTask.checkNotificationPermission();
    if (np != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  static Future<void> start({required String text}) async {
    init();
    if (await FlutterForegroundTask.isRunningService) {
      await update(text);
      return;
    }
    await FlutterForegroundTask.startService(
      serviceId: 1,
      serviceTypes: [ForegroundServiceTypes.mediaPlayback],
      notificationTitle: _title,
      notificationText: text,
      notificationIcon: _icon,
    );
  }

  static Future<void> update(String text) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: _title,
      notificationText: text,
      notificationIcon: _icon,
    );
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

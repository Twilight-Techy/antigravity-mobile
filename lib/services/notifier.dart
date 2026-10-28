import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Tells the user when the agent finishes while the app is in the
/// background, and keeps the app alive while an agent run is in progress.
abstract class Notifier {
  /// `antigravity://` links from tapped notifications.
  Stream<String> get taps;

  Future<void> init();

  /// Asks for permission to post notifications (Android 13+, iOS).
  Future<void> requestPermission();

  /// Keeps the process (and so the SSH connection) alive while the agent
  /// works in the background: a foreground service on Android, a
  /// background task on iOS (which the OS limits to about 30 seconds).
  Future<void> keepAlive(String workspaceName);

  Future<void> releaseKeepAlive();

  Future<void> agentFinished({
    required String link,
    required String title,
    required String body,
  });
}

class LocalNotifier implements Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<String>.broadcast();
  static const _background = MethodChannel('antigravity_mobile/background');
  static const _keepAliveId = 1;
  int _nextId = 100;
  bool _ready = false;
  bool _keepingAlive = false;

  static const _doneChannel = AndroidNotificationDetails(
    'agent_finished',
    'Agent finished',
    channelDescription: 'When the agent finishes a task while the app is in the background',
    importance: Importance.high,
    priority: Priority.high,
  );

  static const _workingChannel = AndroidNotificationDetails(
    'agent_working',
    'Agent working',
    channelDescription: 'Shown while the agent works so the connection stays open',
    importance: Importance.low,
    priority: Priority.low,
    ongoing: true,
    showWhen: false,
    onlyAlertOnce: true,
  );

  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<void> init() async {
    if (_ready || !_supported) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (r) {
          final payload = r.payload;
          if (payload != null && payload.isNotEmpty) _taps.add(payload);
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final payload = launch?.notificationResponse?.payload;
      if (launch?.didNotificationLaunchApp == true && payload != null) {
        scheduleMicrotask(() => _taps.add(payload));
      }
      _ready = true;
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  @override
  Future<void> requestPermission() async {
    if (!_ready) return;
    try {
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, sound: true);
      }
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
  }

  @override
  Future<void> keepAlive(String workspaceName) async {
    if (!_ready || _keepingAlive) return;
    _keepingAlive = true;
    try {
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.startForegroundService(
              id: _keepAliveId,
              title: 'Agent working in $workspaceName',
              body: "You'll get a notification when it's done.",
              notificationDetails: _workingChannel,
              startType: AndroidServiceStartType.startNotSticky,
              foregroundServiceTypes: {AndroidServiceForegroundType.foregroundServiceTypeDataSync},
            );
      } else if (Platform.isIOS) {
        await _background.invokeMethod('begin');
      }
    } catch (e) {
      debugPrint('Could not keep the app alive: $e');
    }
  }

  @override
  Future<void> releaseKeepAlive() async {
    if (!_keepingAlive) return;
    _keepingAlive = false;
    try {
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.stopForegroundService();
      } else if (Platform.isIOS) {
        await _background.invokeMethod('end');
      }
    } catch (e) {
      debugPrint('Could not release keep-alive: $e');
    }
  }

  @override
  Future<void> agentFinished({
    required String link,
    required String title,
    required String body,
  }) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: _doneChannel,
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
        ),
        payload: link,
      );
    } catch (e) {
      debugPrint('Could not show notification: $e');
    }
  }
}

/// Used where notifications are unavailable, and in tests.
class SilentNotifier implements Notifier {
  final _taps = StreamController<String>.broadcast();
  final shown = <(String title, String body, String link)>[];
  bool keptAlive = false;
  int permissionRequests = 0;

  void tap(String link) => _taps.add(link);

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> requestPermission() async => permissionRequests++;

  @override
  Future<void> keepAlive(String workspaceName) async => keptAlive = true;

  @override
  Future<void> releaseKeepAlive() async => keptAlive = false;

  @override
  Future<void> agentFinished({
    required String link,
    required String title,
    required String body,
  }) async =>
      shown.add((title, body, link));
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'notifications_provider.dart';

/// `flutter_local_notifications`-backed [NotificationsProvider]
/// (BUILD_SPEC.md Phase 12.8).
///
/// Lives in its own file so widget + service tests that import
/// `notifications_provider.dart` don't transitively pull the platform
/// plugin (which fails to load in the headless test runner). The
/// production override in `main.dart` is the only path that reaches
/// for this class.
///
/// Initialization is deferred to the first method call (lazy
/// `_ensureInitialized`) so an app run that never touches the
/// trackers never spins the plugin up.
class LocalNotificationsProvider implements NotificationsProvider {
  LocalNotificationsProvider({
    FlutterLocalNotificationsPlugin? plugin,
    void Function(String tzName)? initializeTimezones,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _initTimezones = initializeTimezones ?? _defaultInitTimezones;

  final FlutterLocalNotificationsPlugin _plugin;
  final void Function(String) _initTimezones;
  bool _initialized = false;
  final StreamController<String> _taps = StreamController<String>.broadcast();

  static const String _channelId = 'careblazers_trackers';
  static const String _channelName = 'Tracker reminders';
  static const String _channelDesc =
      'Dose + appointment reminders from Careblazers.';

  static void _defaultInitTimezones(String _) {
    tz_data.initializeTimeZones();
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initTimezones('UTC');
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const InitializationSettings init = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
      macOS: iosInit,
    );
    await _plugin.initialize(
      init,
      onDidReceiveNotificationResponse: _handleTap,
    );
    _initialized = true;
  }

  void _handleTap(NotificationResponse response) {
    final String? payload = response.payload;
    if (payload != null && payload.isNotEmpty) {
      _taps.add(payload);
    }
  }

  @override
  Future<NotificationPermission> requestPermission() async {
    await _ensureInitialized();
    final IOSFlutterLocalNotificationsPlugin? ios = _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final bool? granted =
          await ios.requestPermissions(alert: true, badge: true, sound: true);
      return _grantedFromBool(granted);
    }
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final bool? granted = await android.requestNotificationsPermission();
      return _grantedFromBool(granted);
    }
    return NotificationPermission.notDetermined;
  }

  @override
  Future<NotificationPermission> currentPermission() async {
    await _ensureInitialized();
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final bool? enabled = await android.areNotificationsEnabled();
      return _grantedFromBool(enabled);
    }
    return NotificationPermission.notDetermined;
  }

  @override
  Future<void> schedule(ScheduledNotification notification) async {
    // A notification op must NEVER break the caller's flow. The
    // medication/appointment form save schedules reminders on the same
    // await it shows "Saving…" on — and on Android release the plugin can
    // throw an uncaught PlatformException ("TypeToken must be created with
    // a type argument", from R8/desugaring stripping Gson's generic
    // signature) that hangs the save forever (fb 2026-06-14). Swallow any
    // platform failure here: drop the reminder, let the save complete.
    try {
      await _ensureInitialized();
      final tz.TZDateTime scheduledTz = tz.TZDateTime.from(
        notification.scheduledFor,
        tz.local,
      );
      const NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      );
      await _plugin.zonedSchedule(
        notification.id,
        notification.title,
        notification.body,
        scheduledTz,
        details,
        payload: notification.deepLink,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        // The 17.x plugin still requires this parameter even though
        // `zonedSchedule` always uses TZ-aware interpretation on
        // modern iOS — the named arg is mandatory by signature.
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint('notifications: schedule failed (id ${notification.id}): $e');
    }
  }

  @override
  Future<void> cancelMany(Iterable<int> ids) async {
    // Same fail-safe as [schedule] — `_plugin.cancel` is the exact call
    // that crashes on Android release, so guard it (the save's
    // cancel-then-reschedule pass must not hang on it).
    try {
      await _ensureInitialized();
      for (final int id in ids) {
        await _plugin.cancel(id);
      }
    } catch (e) {
      debugPrint('notifications: cancelMany failed: $e');
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _ensureInitialized();
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('notifications: cancelAll failed: $e');
    }
  }

  @override
  Future<List<ScheduledNotification>> pending() async {
    try {
      await _ensureInitialized();
      final List<PendingNotificationRequest> rows =
          await _plugin.pendingNotificationRequests();
      return List<ScheduledNotification>.unmodifiable(<ScheduledNotification>[
        for (final PendingNotificationRequest r in rows)
          ScheduledNotification(
            id: r.id,
            title: r.title ?? '',
            body: r.body ?? '',
            // The plugin doesn't surface the original scheduledFor —
            // use the wall-clock now() as a placeholder; pending()'s
            // primary use is "count + ids" for the cancel path, not
            // round-tripping the time.
            scheduledFor: DateTime.fromMillisecondsSinceEpoch(0),
            deepLink: r.payload ?? '',
          ),
      ]);
    } catch (e) {
      debugPrint('notifications: pending failed: $e');
      return const <ScheduledNotification>[];
    }
  }

  @override
  Stream<String> taps() => _taps.stream;

  /// Releases the broadcast tap controller — call from app teardown
  /// so the stream doesn't leak.
  @visibleForTesting
  void dispose() {
    _taps.close();
  }

  static NotificationPermission _grantedFromBool(bool? granted) {
    if (granted == null) return NotificationPermission.notDetermined;
    return granted
        ? NotificationPermission.granted
        : NotificationPermission.denied;
  }
}

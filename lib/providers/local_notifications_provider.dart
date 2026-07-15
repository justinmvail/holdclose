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
    Future<bool> Function()? canScheduleExactAlarms,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _initTimezones = initializeTimezones ?? _defaultInitTimezones,
        _canScheduleExactAlarmsOverride = canScheduleExactAlarms;

  final FlutterLocalNotificationsPlugin _plugin;
  final void Function(String) _initTimezones;

  /// Test seam for "may this build schedule an exact alarm?" — production
  /// leaves it null and the answer is resolved from the Android plugin
  /// ([_canScheduleExact]).
  final Future<bool> Function()? _canScheduleExactAlarmsOverride;
  bool _initialized = false;
  final StreamController<String> _taps = StreamController<String>.broadcast();

  /// Surfaces a scheduling/cancel failure the OS layer swallowed to keep
  /// the caller's save from hanging (see [schedule]). A production run can
  /// listen and warn the caregiver that a reminder didn't land instead of
  /// the failure vanishing into a debugPrint. Broadcast so both the boot
  /// wiring and a future in-app banner can subscribe.
  final StreamController<NotificationScheduleFailure> _failures =
      StreamController<NotificationScheduleFailure>.broadcast();

  /// Stream of scheduling failures. Empty on the happy path; emits one
  /// [NotificationScheduleFailure] per swallowed platform exception so the
  /// caller can surface "we couldn't set that reminder" without the save
  /// itself failing.
  Stream<NotificationScheduleFailure> scheduleFailures() => _failures.stream;

  static const String _channelId = 'holdclose_trackers';
  static const String _channelName = 'Tracker reminders';
  static const String _channelDesc =
      'Dose + appointment reminders from Holdclose.';

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
    // await it shows "Saving…" on — so a platform exception here can't be
    // rethrown or it would hang the save. But it must NOT vanish silently:
    // if the reminder failed to land the caregiver has to know. Catch the
    // failure so the save completes, then SURFACE it on [scheduleFailures]
    // (and log) rather than dropping it into a debugPrint.
    //
    // The historical failure was an uncaught PlatformException on Android
    // release ("TypeToken must be created with a type argument", from
    // R8/desugaring stripping Gson's generic signature, fb 2026-06-14) —
    // now covered by the -keepattributes Signature keep-rule in
    // proguard-rules.pro, but the guard stays as a fail-safe.
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
        androidScheduleMode: await _resolveScheduleMode(),
        // The 17.x plugin still requires this parameter even though
        // `zonedSchedule` always uses TZ-aware interpretation on
        // modern iOS — the named arg is mandatory by signature.
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e, stack) {
      _reportFailure(
        'schedule failed (id ${notification.id})',
        e,
        stack,
        notificationId: notification.id,
      );
    }
  }

  /// Pick the Android alarm scheduling mode.
  ///
  /// We prefer EXACT timing for dose + appointment reminders — a medication
  /// window is only useful if it fires on time. But the app is not an alarm-
  /// clock or calendar app, so it may NOT declare `USE_EXACT_ALARM` (Play
  /// policy restricts that to those two categories). It keeps
  /// `SCHEDULE_EXACT_ALARM`, which a reminder app is allowed to use — but on
  /// Android 14+ that is NOT auto-granted, so exact scheduling can be
  /// disallowed at runtime. When it is, scheduling an exact alarm throws and
  /// the reminder would silently never fire. So: use exact when the OS
  /// permits it, and fall back to INEXACT (still fires, just Doze-batched)
  /// otherwise. On iOS/macOS the mode is ignored by the OS layer.
  Future<AndroidScheduleMode> _resolveScheduleMode() async {
    final bool canExact = await _canScheduleExact();
    return canExact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
  }

  Future<bool> _canScheduleExact() async {
    final Future<bool> Function()? override = _canScheduleExactAlarmsOverride;
    if (override != null) return override();
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    // Not Android (iOS/macOS): the schedule mode is ignored there, so the
    // answer is moot — report true so we pass the "exact" mode the plugin
    // signature wants.
    if (android == null) return true;
    return await android.canScheduleExactNotifications() ?? false;
  }

  /// Log a swallowed platform failure loudly (with stack) and emit it on
  /// [scheduleFailures] so a listener can surface it. Never rethrows — the
  /// caller's save must still complete.
  void _reportFailure(
    String what,
    Object error,
    StackTrace stack, {
    int? notificationId,
  }) {
    debugPrintStack(
      label: 'notifications: $what: $error',
      stackTrace: stack,
    );
    if (!_failures.isClosed) {
      _failures.add(NotificationScheduleFailure(
        message: what,
        error: error,
        notificationId: notificationId,
      ));
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
    } catch (e, stack) {
      _reportFailure('cancelMany failed', e, stack);
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _ensureInitialized();
      await _plugin.cancelAll();
    } catch (e, stack) {
      _reportFailure('cancelAll failed', e, stack);
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
    } catch (e, stack) {
      // Route through [_reportFailure] like the schedule/cancel paths so a
      // swallowed read failure is observable on [scheduleFailures] instead
      // of vanishing into a bare debugPrint. Still returns an empty list —
      // pending() must never rethrow into the caller's flow.
      _reportFailure('pending failed', e, stack);
      return const <ScheduledNotification>[];
    }
  }

  @override
  Stream<String> taps() => _taps.stream;

  /// Releases the broadcast controllers — call from app teardown so the
  /// tap + failure streams don't leak.
  @visibleForTesting
  void dispose() {
    _taps.close();
    _failures.close();
  }

  static NotificationPermission _grantedFromBool(bool? granted) {
    if (granted == null) return NotificationPermission.notDetermined;
    return granted
        ? NotificationPermission.granted
        : NotificationPermission.denied;
  }
}

/// A platform-layer notification op ([LocalNotificationsProvider.schedule]
/// and the cancel paths) that the provider had to swallow to keep the
/// caller's save from hanging. Surfaced on
/// [LocalNotificationsProvider.scheduleFailures] so the failure is visible
/// (loggable / bannerable) instead of vanishing into a debugPrint.
@immutable
class NotificationScheduleFailure {
  const NotificationScheduleFailure({
    required this.message,
    required this.error,
    this.notificationId,
  });

  /// Human-readable summary of which op failed (e.g.
  /// `'schedule failed (id 42)'`).
  final String message;

  /// The caught platform error.
  final Object error;

  /// The [ScheduledNotification.id] involved, when the failure was tied to
  /// a specific reminder (null for the bulk cancel paths).
  final int? notificationId;

  @override
  String toString() => 'NotificationScheduleFailure($message: $error)';
}

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/providers/local_notifications_provider.dart';
import 'package:holdclose/providers/notifications_provider.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Test double for the platform plugin. [LocalNotificationsProvider] takes a
/// plugin in its constructor so these tests never touch the OS layer — the
/// fake records happy-path calls and can be told to throw so the
/// failure-surfacing path (the point of the fix) is exercised.
///
/// `implements` (not `extends`) because the plugin's only constructor is
/// private; `noSuchMethod` stubs the members these tests don't drive.
class _FakePlugin implements FlutterLocalNotificationsPlugin {
  bool throwOnSchedule = false;
  bool throwOnCancel = false;
  bool throwOnPending = false;
  final List<int> scheduled = <int>[];
  final List<int> cancelled = <int>[];
  bool cancelAllCalled = false;
  AndroidScheduleMode? lastScheduleMode;

  @override
  Future<bool?> initialize(
    InitializationSettings initializationSettings, {
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async =>
      true;

  @override
  Future<void> zonedSchedule(
    int id,
    String? title,
    String? body,
    dynamic scheduledDate,
    NotificationDetails notificationDetails, {
    UILocalNotificationDateInterpretation? uiLocalNotificationDateInterpretation,
    required AndroidScheduleMode androidScheduleMode,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    if (throwOnSchedule) {
      throw PlatformException(
        code: 'error',
        message: 'TypeToken must be created with a type argument',
      );
    }
    lastScheduleMode = androidScheduleMode;
    scheduled.add(id);
  }

  @override
  Future<void> cancel(int id, {String? tag}) async {
    if (throwOnCancel) {
      throw PlatformException(code: 'error', message: 'boom');
    }
    cancelled.add(id);
  }

  @override
  Future<void> cancelAll() async {
    if (throwOnCancel) {
      throw PlatformException(code: 'error', message: 'boom');
    }
    cancelAllCalled = true;
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    if (throwOnPending) {
      throw PlatformException(code: 'error', message: 'boom');
    }
    return <PendingNotificationRequest>[];
  }

  // Only unstubbed call left is resolvePlatformSpecificImplementation (the
  // default schedule path uses it to decide exact-vs-inexact). Its return is
  // nullable, and a headless test has no platform impl, so null is correct —
  // the provider then treats it as "not Android", where the mode is moot.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

ScheduledNotification _notification({int id = 1}) => ScheduledNotification(
      id: id,
      title: 'Time for Lisinopril',
      body: '10 mg — tap to mark it taken.',
      scheduledFor: DateTime(2030, 1, 1, 8),
      deepLink: '/medications/today',
    );

void main() {
  // schedule() converts scheduledFor through tz.TZDateTime.from(_, tz.local),
  // so tz.local must resolve. Load the tz database once and pin UTC — the
  // provider's own initializer is stubbed out below so the plugin's
  // platform init never runs, but the timezone lookup still has to succeed.
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('UTC'));
  });

  LocalNotificationsProvider build(
    _FakePlugin plugin, {
    Future<bool> Function()? canScheduleExactAlarms,
  }) =>
      LocalNotificationsProvider(
        plugin: plugin,
        initializeTimezones: (_) {},
        canScheduleExactAlarms: canScheduleExactAlarms,
      );

  test('schedule forwards to the plugin on the happy path', () async {
    final _FakePlugin plugin = _FakePlugin();
    final LocalNotificationsProvider provider = build(plugin);
    addTearDown(provider.dispose);

    await provider.schedule(_notification(id: 42));

    expect(plugin.scheduled, <int>[42]);
  });

  test('schedules an EXACT alarm when the OS permits it', () async {
    final _FakePlugin plugin = _FakePlugin();
    final LocalNotificationsProvider provider =
        build(plugin, canScheduleExactAlarms: () async => true);
    addTearDown(provider.dispose);

    await provider.schedule(_notification());

    expect(plugin.lastScheduleMode, AndroidScheduleMode.exactAllowWhileIdle);
  });

  test(
    'falls back to an INEXACT alarm when exact is not permitted '
    '(Android 14+ without SCHEDULE_EXACT_ALARM) so the reminder still fires',
    () async {
      final _FakePlugin plugin = _FakePlugin();
      final LocalNotificationsProvider provider =
          build(plugin, canScheduleExactAlarms: () async => false);
      addTearDown(provider.dispose);

      await provider.schedule(_notification());

      // The reminder is still scheduled — just Doze-batched, never dropped.
      expect(plugin.scheduled, isNotEmpty);
      expect(
        plugin.lastScheduleMode,
        AndroidScheduleMode.inexactAllowWhileIdle,
      );
    },
  );

  test('a scheduling failure is surfaced on scheduleFailures, not swallowed',
      () async {
    final _FakePlugin plugin = _FakePlugin()..throwOnSchedule = true;
    final LocalNotificationsProvider provider = build(plugin);
    addTearDown(provider.dispose);

    final Future<NotificationScheduleFailure> firstFailure =
        provider.scheduleFailures().first;

    // The save's await must complete even though the plugin threw — the
    // failure is reported out-of-band, never rethrown into the caller.
    await provider.schedule(_notification(id: 7));

    final NotificationScheduleFailure failure = await firstFailure;
    expect(failure.notificationId, 7);
    expect(failure.message, contains('schedule failed'));
    expect(failure.error, isA<PlatformException>());
  });

  test('a cancelMany failure is surfaced without rethrowing', () async {
    final _FakePlugin plugin = _FakePlugin()..throwOnCancel = true;
    final LocalNotificationsProvider provider = build(plugin);
    addTearDown(provider.dispose);

    final Future<NotificationScheduleFailure> firstFailure =
        provider.scheduleFailures().first;

    await provider.cancelMany(<int>[1, 2]);

    final NotificationScheduleFailure failure = await firstFailure;
    expect(failure.message, contains('cancelMany failed'));
    expect(failure.notificationId, isNull);
  });

  test('a pending() read failure is surfaced, not swallowed', () async {
    final _FakePlugin plugin = _FakePlugin()..throwOnPending = true;
    final LocalNotificationsProvider provider = build(plugin);
    addTearDown(provider.dispose);

    final Future<NotificationScheduleFailure> firstFailure =
        provider.scheduleFailures().first;

    // pending() returns an empty list rather than rethrowing, but the
    // failure is now observable on scheduleFailures like the other paths.
    final List<ScheduledNotification> rows = await provider.pending();
    expect(rows, isEmpty);

    final NotificationScheduleFailure failure = await firstFailure;
    expect(failure.message, contains('pending failed'));
    expect(failure.notificationId, isNull);
  });

  test('cancelMany forwards each id on the happy path', () async {
    final _FakePlugin plugin = _FakePlugin();
    final LocalNotificationsProvider provider = build(plugin);
    addTearDown(provider.dispose);

    await provider.cancelMany(<int>[3, 4, 5]);

    expect(plugin.cancelled, <int>[3, 4, 5]);
  });

  test('scheduleFailures stays silent when everything succeeds', () async {
    final _FakePlugin plugin = _FakePlugin();
    final LocalNotificationsProvider provider = build(plugin);
    addTearDown(provider.dispose);

    NotificationScheduleFailure? seen;
    final sub = provider.scheduleFailures().listen((f) => seen = f);
    addTearDown(sub.cancel);

    await provider.schedule(_notification());
    await provider.cancelAll();
    // Let the (empty) stream settle.
    await Future<void>.delayed(Duration.zero);

    expect(seen, isNull);
    expect(plugin.cancelAllCalled, isTrue);
  });
}

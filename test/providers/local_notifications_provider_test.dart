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
  final List<int> scheduled = <int>[];
  final List<int> cancelled = <int>[];
  bool cancelAllCalled = false;

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  LocalNotificationsProvider build(_FakePlugin plugin) =>
      LocalNotificationsProvider(
        plugin: plugin,
        initializeTimezones: (_) {},
      );

  test('schedule forwards to the plugin on the happy path', () async {
    final _FakePlugin plugin = _FakePlugin();
    final LocalNotificationsProvider provider = build(plugin);
    addTearDown(provider.dispose);

    await provider.schedule(_notification(id: 42));

    expect(plugin.scheduled, <int>[42]);
  });

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

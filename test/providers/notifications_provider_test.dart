import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/notifications_provider.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NoopNotificationsProvider — recording fake', () {
    test('schedule + pending round-trip preserves the entry', () async {
      final NoopNotificationsProvider noop = NoopNotificationsProvider();
      addTearDown(noop.dispose);

      final ScheduledNotification n = ScheduledNotification(
        id: 42,
        title: 'Time for Donepezil',
        body: '10 mg',
        scheduledFor: DateTime.utc(2026, 6, 1, 8, 0),
        deepLink: '/medications/today',
      );
      await noop.schedule(n);

      final List<ScheduledNotification> pending = await noop.pending();
      expect(pending, <ScheduledNotification>[n]);
    });

    test('schedule on existing id replaces the prior entry', () async {
      final NoopNotificationsProvider noop = NoopNotificationsProvider();
      addTearDown(noop.dispose);

      await noop.schedule(ScheduledNotification(
        id: 7,
        title: 'first',
        body: 'b',
        scheduledFor: DateTime.utc(2026, 6, 1),
        deepLink: '/x',
      ));
      await noop.schedule(ScheduledNotification(
        id: 7,
        title: 'second',
        body: 'b',
        scheduledFor: DateTime.utc(2026, 6, 2),
        deepLink: '/y',
      ));
      final List<ScheduledNotification> pending = await noop.pending();
      expect(pending.length, 1);
      expect(pending.single.title, 'second');
      expect(pending.single.deepLink, '/y');
    });

    test('cancelMany drops matching ids only', () async {
      final NoopNotificationsProvider noop = NoopNotificationsProvider();
      addTearDown(noop.dispose);

      for (int i = 0; i < 3; i++) {
        await noop.schedule(ScheduledNotification(
          id: i,
          title: 't$i',
          body: 'b',
          scheduledFor: DateTime.utc(2026, 6, 1 + i),
          deepLink: '/x',
        ));
      }
      await noop.cancelMany(<int>[0, 2, 999 /* not present */]);
      final List<int> remaining = (await noop.pending())
          .map((ScheduledNotification n) => n.id)
          .toList();
      expect(remaining, <int>[1]);
    });

    test('cancelAll clears every pending entry', () async {
      final NoopNotificationsProvider noop = NoopNotificationsProvider();
      addTearDown(noop.dispose);

      await noop.schedule(ScheduledNotification(
        id: 1,
        title: 't',
        body: 'b',
        scheduledFor: DateTime.utc(2026, 6, 1),
        deepLink: '/x',
      ));
      await noop.cancelAll();
      expect(await noop.pending(), isEmpty);
    });

    test('requestPermission returns the seeded grant + counts calls',
        () async {
      final NoopNotificationsProvider noop = NoopNotificationsProvider(
        seedPermission: NotificationPermission.denied,
      );
      addTearDown(noop.dispose);

      expect(await noop.currentPermission(), NotificationPermission.denied);
      expect(await noop.requestPermission(), NotificationPermission.denied);
      noop.setPermission(NotificationPermission.granted);
      expect(await noop.requestPermission(), NotificationPermission.granted);
      expect(noop.requestCount, 2);
    });

    test('simulateTap emits on the taps stream', () async {
      final NoopNotificationsProvider noop = NoopNotificationsProvider();
      addTearDown(noop.dispose);

      final List<String> received = <String>[];
      final sub = noop.taps().listen(received.add);
      addTearDown(sub.cancel);

      noop.simulateTap('/medications/today');
      noop.simulateTap('/appointments/appt-1');
      await Future<void>.delayed(Duration.zero);

      expect(received, <String>['/medications/today', '/appointments/appt-1']);
    });
  });

  group('doseNotificationId / appointmentNotificationId — id derivation', () {
    test('same medication id + dose index => same notification id', () {
      expect(doseNotificationId('med-A', 0),
          doseNotificationId('med-A', 0));
      expect(doseNotificationId('med-A', 0),
          isNot(doseNotificationId('med-A', 1)));
      expect(doseNotificationId('med-A', 0),
          isNot(doseNotificationId('med-B', 0)));
    });

    test('appointment 24h vs 1h ids are distinct', () {
      expect(appointmentNotificationId('appt-A', 24),
          isNot(appointmentNotificationId('appt-A', 1)));
      expect(appointmentNotificationId('appt-A', 24),
          appointmentNotificationId('appt-A', 24));
    });
  });

  group('doseReminders — expand a Medication schedule', () {
    Medication med() => const Medication(
          id: 'med-1',
          name: 'Donepezil',
          dosage: '10 mg',
          route: MedicationRoute.oral,
        );

    test('daily 8am schedule yields one reminder at the next 8am', () {
      final DateTime now = DateTime(2026, 6, 1, 6, 0);
      final List<ScheduledNotification> out = doseReminders(
        medication: med(),
        schedules: <DoseSchedule>[
          DoseSchedule(
            id: 's',
            medicationId: 'med-1',
            frequencyKind: FrequencyKind.daily,
            timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
            daysOfWeek: const <int>{},
            startsOn: DateTime(2026, 5, 1),
          ),
        ],
        now: now,
      );
      expect(out.length, 1);
      expect(out.single.scheduledFor, DateTime(2026, 6, 1, 8, 0));
      expect(out.single.deepLink, '/medications/today');
      expect(out.single.title, contains('Donepezil'));
    });

    test('twice-daily schedule rolls to the next-day 8am after a 9am now', () {
      final DateTime now = DateTime(2026, 6, 1, 21, 0);
      final List<ScheduledNotification> out = doseReminders(
        medication: med(),
        schedules: <DoseSchedule>[
          DoseSchedule(
            id: 's',
            medicationId: 'med-1',
            frequencyKind: FrequencyKind.twiceDaily,
            timesOfDay: const <TimeOfDay>[
              TimeOfDay(hour: 8, minute: 0),
              TimeOfDay(hour: 20, minute: 0),
            ],
            daysOfWeek: const <int>{},
            startsOn: DateTime(2026, 5, 1),
          ),
        ],
        now: now,
      );
      expect(out.length, 2);
      // After 8pm — both rolled to tomorrow.
      expect(out[0].scheduledFor, DateTime(2026, 6, 2, 8, 0));
      expect(out[1].scheduledFor, DateTime(2026, 6, 2, 20, 0));
    });

    test('asNeeded schedules yield nothing', () {
      final List<ScheduledNotification> out = doseReminders(
        medication: med(),
        schedules: <DoseSchedule>[
          DoseSchedule(
            id: 's',
            medicationId: 'med-1',
            frequencyKind: FrequencyKind.asNeeded,
            timesOfDay: const <TimeOfDay>[],
            daysOfWeek: const <int>{},
            startsOn: DateTime(2026, 5, 1),
          ),
        ],
        now: DateTime(2026, 6, 1, 6, 0),
      );
      expect(out, isEmpty);
    });

    test('schedule past endsOn yields nothing', () {
      final List<ScheduledNotification> out = doseReminders(
        medication: med(),
        schedules: <DoseSchedule>[
          DoseSchedule(
            id: 's',
            medicationId: 'med-1',
            frequencyKind: FrequencyKind.daily,
            timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
            daysOfWeek: const <int>{},
            startsOn: DateTime(2026, 5, 1),
            endsOn: DateTime(2026, 5, 31, 23, 59),
          ),
        ],
        now: DateTime(2026, 6, 1, 6, 0),
      );
      expect(out, isEmpty);
    });
  });

  group('appointmentReminders — 24h + 1h before startsAt', () {
    Provider provider() => const Provider(
          id: 'prov-1',
          name: 'Dr. Patel',
          role: ProviderRole.neurologist,
          phone: '555-0100',
          address: '1 Med Way',
        );

    test('yields both reminders when both windows are in the future', () {
      final DateTime now = DateTime(2026, 6, 1, 8, 0);
      final Appointment appt = Appointment(
        id: 'appt-1',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 5, 10, 0),
        durationMinutes: 30,
        location: '1 Med Way',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      );
      final List<ScheduledNotification> out = appointmentReminders(
        appointment: appt,
        provider: provider(),
        now: now,
      );
      expect(out.length, 2);
      expect(out[0].scheduledFor, DateTime(2026, 6, 4, 10, 0));
      expect(out[1].scheduledFor, DateTime(2026, 6, 5, 9, 0));
      expect(out[0].deepLink, '/appointments/appt-1');
      expect(out[1].body, contains('Dr. Patel'));
    });

    test('drops the 24h reminder when the window already slipped', () {
      // now is 12h before the visit — only the 1h reminder is still valid.
      final DateTime now = DateTime(2026, 6, 4, 22, 0);
      final Appointment appt = Appointment(
        id: 'appt-2',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 5, 10, 0),
        durationMinutes: 30,
        location: '1 Med Way',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      );
      final List<ScheduledNotification> out = appointmentReminders(
        appointment: appt,
        provider: provider(),
        now: now,
      );
      expect(out.length, 1);
      expect(out.single.scheduledFor, DateTime(2026, 6, 5, 9, 0));
    });

    test('cancelled / completed appointments yield no reminders', () {
      final Appointment cancelled = Appointment(
        id: 'appt-3',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 5, 10, 0),
        durationMinutes: 30,
        location: '1 Med Way',
        agenda: const <String>[],
        status: AppointmentStatus.canceled,
      );
      expect(
        appointmentReminders(
          appointment: cancelled,
          provider: provider(),
          now: DateTime(2026, 6, 1),
        ),
        isEmpty,
      );
    });

    test('missing provider falls back to a generic name in the body', () {
      final DateTime now = DateTime(2026, 6, 1, 8, 0);
      final Appointment appt = Appointment(
        id: 'appt-4',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 5, 10, 0),
        durationMinutes: 30,
        location: '1 Med Way',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      );
      final List<ScheduledNotification> out = appointmentReminders(
        appointment: appt,
        provider: null,
        now: now,
      );
      expect(out.first.body, contains('your provider'));
    });
  });
}

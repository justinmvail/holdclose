import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/notifications_provider.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/services/notification_scheduler.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationScheduler — BUILD_SPEC.md Phase 12.8', () {
    late CareblazersDatabase db;
    late MedicationRepository medRepo;
    late AppointmentRepository apptRepo;
    late ProviderRepository providerRepo;
    late NoopNotificationsProvider noop;
    final DateTime now = DateTime(2026, 6, 1, 6, 0);
    DateTime clock() => now;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      medRepo = MedicationRepository(db, clock: clock);
      apptRepo = AppointmentRepository(db, clock: clock);
      providerRepo = ProviderRepository(db);
      noop = NoopNotificationsProvider();
    });

    tearDown(() async {
      noop.dispose();
      await db.close();
    });

    NotificationScheduler scheduler({AppSettings? settings}) =>
        NotificationScheduler(
          notifications: noop,
          medicationRepository: medRepo,
          appointmentRepository: apptRepo,
          settings: settings ?? AppSettings.defaults(),
          clock: clock,
        );

    Future<void> seedMed() async {
      await medRepo.upsertMedication(const Medication(
        id: 'med-1',
        name: 'Donepezil',
        dosage: '10 mg',
        route: MedicationRoute.oral,
      ));
      await medRepo.upsertSchedule(DoseSchedule(
        id: 'sched-1',
        medicationId: 'med-1',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
    }

    Future<void> seedAppt() async {
      await providerRepo.upsertProvider(const Provider(
        id: 'prov-1',
        name: 'Dr. Patel',
        role: ProviderRole.neurologist,
        phone: '555-0100',
        address: '1 Med Way',
      ));
      await apptRepo.upsertAppointment(Appointment(
        id: 'appt-1',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 5, 10, 0),
        durationMinutes: 30,
        location: '1 Med Way',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      ));
    }

    test('rescheduleForMedication schedules one reminder per time-of-day',
        () async {
      await seedMed();
      final List<ScheduledNotification> targets =
          await scheduler().rescheduleForMedication('med-1');
      expect(targets.length, 1);
      expect((await noop.pending()).length, 1);
      expect(targets.single.scheduledFor, DateTime(2026, 6, 1, 8, 0));
    });

    test('rescheduleForMedication on a re-edit overwrites prior reminders',
        () async {
      await seedMed();
      await scheduler().rescheduleForMedication('med-1');
      // Edit: bump to twice-daily.
      await medRepo.upsertSchedule(DoseSchedule(
        id: 'sched-1',
        medicationId: 'med-1',
        frequencyKind: FrequencyKind.twiceDaily,
        timesOfDay: const <TimeOfDay>[
          TimeOfDay(hour: 8, minute: 0),
          TimeOfDay(hour: 20, minute: 0),
        ],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      await scheduler().rescheduleForMedication('med-1');
      final List<ScheduledNotification> pending = await noop.pending();
      expect(pending.length, 2);
      // Distinct ids per time-of-day slot.
      expect(pending.map((n) => n.id).toSet().length, 2);
    });

    test('rescheduleForAppointment schedules 24h + 1h reminders', () async {
      await seedAppt();
      final List<ScheduledNotification> targets =
          await scheduler().rescheduleForAppointment('appt-1');
      expect(targets.length, 2);
      expect((await noop.pending()).length, 2);
    });

    test('cancelForMedication wipes its reminders without scheduling new ones',
        () async {
      await seedMed();
      await scheduler().rescheduleForMedication('med-1');
      expect((await noop.pending()).length, 1);
      await scheduler().cancelForMedication('med-1');
      expect(await noop.pending(), isEmpty);
    });

    test('cancelForAppointment wipes both 24h + 1h reminders', () async {
      await seedAppt();
      await scheduler().rescheduleForAppointment('appt-1');
      expect((await noop.pending()).length, 2);
      await scheduler().cancelForAppointment('appt-1');
      expect(await noop.pending(), isEmpty);
    });

    test('master useTrackers OFF blocks scheduling but still cancels',
        () async {
      await seedMed();
      // Land a stale pending reminder first.
      await scheduler().rescheduleForMedication('med-1');
      expect((await noop.pending()).length, 1);

      // Now the caregiver turns trackers off — re-schedule should cancel.
      final AppSettings off =
          AppSettings.defaults().copyWith(useTrackers: false);
      final List<ScheduledNotification> targets =
          await scheduler(settings: off).rescheduleForMedication('med-1');
      expect(targets, isEmpty);
      expect(await noop.pending(), isEmpty,
          reason: 'A turn-off must clear the prior pending reminder.');
    });

    test('per-feature medicationsEnabled OFF skips scheduling', () async {
      await seedMed();
      final AppSettings off =
          AppSettings.defaults().copyWith(medicationsEnabled: false);
      final List<ScheduledNotification> targets =
          await scheduler(settings: off).rescheduleForMedication('med-1');
      expect(targets, isEmpty);
      expect(await noop.pending(), isEmpty);
    });

    test('per-feature appointmentsEnabled OFF skips appointment scheduling',
        () async {
      await seedAppt();
      final AppSettings off =
          AppSettings.defaults().copyWith(appointmentsEnabled: false);
      final List<ScheduledNotification> targets =
          await scheduler(settings: off).rescheduleForAppointment('appt-1');
      expect(targets, isEmpty);
      expect(await noop.pending(), isEmpty);
    });

    test('notificationsEnabled OFF skips scheduling even when trackers on',
        () async {
      await seedMed();
      final AppSettings off =
          AppSettings.defaults().copyWith(notificationsEnabled: false);
      final List<ScheduledNotification> targets =
          await scheduler(settings: off).rescheduleForMedication('med-1');
      expect(targets, isEmpty);
      expect(await noop.pending(), isEmpty);
    });

    test('cancelAll wipes every pending reminder', () async {
      await seedMed();
      await seedAppt();
      final NotificationScheduler s = scheduler();
      await s.rescheduleForMedication('med-1');
      await s.rescheduleForAppointment('appt-1');
      expect((await noop.pending()).length, 3);
      await s.cancelAll();
      expect(await noop.pending(), isEmpty);
    });

    test('unknown medication id reschedule is a no-op (still cancels prior)',
        () async {
      final List<ScheduledNotification> out =
          await scheduler().rescheduleForMedication('does-not-exist');
      expect(out, isEmpty);
    });
  });
}

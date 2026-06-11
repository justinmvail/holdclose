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

/// NotificationScheduler coverage against the recording
/// [NoopNotificationsProvider] (the seam BUILD_SPEC §1 promised tests
/// would use). Pins a fixed clock so "next occurrence" math is
/// deterministic — dose reminders schedule at the window's anchor time,
/// appointment reminders fire 24h + 1h out, the settings gate suppresses
/// scheduling, and a re-schedule replaces (never duplicates) prior
/// reminders by id.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A Monday at 09:00 so an 08:00 daily window's "next" is tomorrow 08:00.
  final DateTime now = DateTime(2026, 6, 8, 9, 0);

  late CareblazersDatabase db;
  late MedicationRepository meds;
  late AppointmentRepository appts;
  late ProviderRepository providers;
  late NoopNotificationsProvider notifications;

  NotificationScheduler scheduler({bool enabled = true}) => NotificationScheduler(
        notifications: notifications,
        medicationRepository: meds,
        appointmentRepository: appts,
        settings: AppSettings.defaults().copyWith(notificationsEnabled: enabled),
        clock: () => now,
      );

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    meds = MedicationRepository(db, clock: () => now);
    appts = AppointmentRepository(db, clock: () => now);
    providers = ProviderRepository(db);
    notifications = NoopNotificationsProvider();
  });

  tearDown(() async {
    notifications.dispose();
    await db.close();
  });

  group('rescheduleForMedication', () {
    Future<void> seedDailyDose() async {
      await meds.upsertMedication(const Medication(
        id: 'm-don',
        name: 'Donepezil',
        dosage: '10 mg',
        route: MedicationRoute.oral,
      ));
      await meds.upsertWindow(const DoseWindow(
        id: 'w-am',
        patientId: 'p1',
        label: 'Morning',
        anchorTime: TimeOfDay(hour: 8, minute: 0),
        sortOrder: 0,
      ));
      await meds.upsertEntry(MedicationWindowEntry(
        id: 'e-don',
        medicationId: 'm-don',
        windowId: 'w-am',
        daysOfWeek: const <int>{}, // every day
        startsOn: DateTime(2026, 1, 1),
      ));
    }

    test('schedules a dose reminder at the window anchor with the '
        'dose-log deep link', () async {
      await seedDailyDose();
      final List<ScheduledNotification> targets =
          await scheduler().rescheduleForMedication('m-don');

      expect(targets, hasLength(1));
      final ScheduledNotification n = targets.single;
      expect(n.title, contains('Donepezil'));
      expect(n.deepLink, '/medications/today');
      // 09:00 "now" is past today's 08:00 window → next is tomorrow 08:00.
      expect(n.scheduledFor, DateTime(2026, 6, 9, 8, 0));
      expect(await notifications.pending(), hasLength(1));
    });

    test('a second reschedule REPLACES rather than duplicates (idempotent '
        'by id)', () async {
      await seedDailyDose();
      final NotificationScheduler s = scheduler();
      await s.rescheduleForMedication('m-don');
      await s.rescheduleForMedication('m-don');
      expect(await notifications.pending(), hasLength(1));
    });

    test('the settings gate OFF schedules nothing (but still clears prior)',
        () async {
      await seedDailyDose();
      // First schedule with the gate on.
      await scheduler().rescheduleForMedication('m-don');
      expect(await notifications.pending(), hasLength(1));
      // Re-run with the gate off → prior reminder cancelled, none added.
      final List<ScheduledNotification> targets =
          await scheduler(enabled: false).rescheduleForMedication('m-don');
      expect(targets, isEmpty);
      expect(await notifications.pending(), isEmpty);
    });

    test('an as-needed window schedules no reminder', () async {
      await meds.upsertMedication(const Medication(
        id: 'm-prn',
        name: 'Lorazepam',
        dosage: '0.5 mg',
        route: MedicationRoute.oral,
      ));
      await meds.upsertWindow(const DoseWindow(
        id: 'w-prn',
        patientId: 'p1',
        label: 'As needed',
        anchorTime: null,
        sortOrder: 9,
      ));
      await meds.upsertEntry(MedicationWindowEntry(
        id: 'e-prn',
        medicationId: 'm-prn',
        windowId: 'w-prn',
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 1, 1),
      ));

      final List<ScheduledNotification> targets =
          await scheduler().rescheduleForMedication('m-prn');
      expect(targets, isEmpty);
    });

    test('cancelForMedication clears the reminder', () async {
      await seedDailyDose();
      final NotificationScheduler s = scheduler();
      await s.rescheduleForMedication('m-don');
      expect(await notifications.pending(), hasLength(1));
      await s.cancelForMedication('m-don');
      expect(await notifications.pending(), isEmpty);
    });
  });

  group('rescheduleForAppointment', () {
    Future<void> seedUpcomingAppt() async {
      await providers.upsertProvider(const Provider(
        id: 'pr-1',
        name: 'Dr. Ortega',
        role: ProviderRole.doctor,
        phone: '555-0100',
        address: '1 Clinic Way',
      ));
      await appts.upsertAppointment(Appointment(
        id: 'a-1',
        providerId: 'pr-1',
        // 3 days out so BOTH the 24h and 1h reminders are still future.
        startsAt: DateTime(2026, 6, 11, 14, 0),
        durationMinutes: 30,
        location: 'Neurology clinic',
        agenda: const <String>['Med review'],
        status: AppointmentStatus.upcoming,
      ));
    }

    test('schedules the 24h + 1h reminders with the appointment deep link',
        () async {
      await seedUpcomingAppt();
      final List<ScheduledNotification> targets =
          await scheduler().rescheduleForAppointment('a-1');

      expect(targets, hasLength(2));
      expect(
        targets.map((ScheduledNotification n) => n.scheduledFor).toSet(),
        <DateTime>{
          DateTime(2026, 6, 10, 14, 0), // 24h before
          DateTime(2026, 6, 11, 13, 0), // 1h before
        },
      );
      expect(
        targets.every((ScheduledNotification n) =>
            n.deepLink == '/appointments/a-1'),
        isTrue,
      );
      expect(
        targets.every((ScheduledNotification n) => n.body.contains('Dr. Ortega')),
        isTrue,
      );
    });

    test('a canceled appointment schedules nothing', () async {
      await seedUpcomingAppt();
      await appts.upsertAppointment(Appointment(
        id: 'a-1',
        providerId: 'pr-1',
        startsAt: DateTime(2026, 6, 11, 14, 0),
        durationMinutes: 30,
        location: 'Neurology clinic',
        agenda: const <String>['Med review'],
        status: AppointmentStatus.canceled,
      ));
      final List<ScheduledNotification> targets =
          await scheduler().rescheduleForAppointment('a-1');
      expect(targets, isEmpty);
    });

    test('cancelAll clears every scheduled reminder', () async {
      await seedUpcomingAppt();
      final NotificationScheduler s = scheduler();
      await s.rescheduleForAppointment('a-1');
      expect((await notifications.pending()).isNotEmpty, isTrue);
      await s.cancelAll();
      expect(await notifications.pending(), isEmpty);
    });
  });
}

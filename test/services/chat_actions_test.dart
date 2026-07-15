import 'package:holdclose/db/database.dart';
// `Provider` (clinician) is hidden so it doesn't collide with riverpod's.
import 'package:holdclose/models/appointment.dart' hide Provider;
import 'package:holdclose/models/care_plan_routine.dart';
import 'package:holdclose/models/care_task.dart';
import 'package:holdclose/models/health_log_entry.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_actions.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Coverage for the chat "action harness" executors (TASKS.md Phase 11.3,
/// extended) — the tools the coach invokes to mutate app state. Each test
/// drives an executor from [buildChatActions] against an in-memory
/// medication repo and asserts the write (or the no-op when args are
/// missing / unresolvable).

DateTime _fixedClock() => DateTime(2026, 6, 4, 9, 0);

/// A throwaway provider so the test can hand [buildChatActions] a real
/// [Ref] (it captures one to reach each repository).
final _actionsProvider = Provider<Map<String, ChatActionExecutor>>(
  (Ref ref) => buildChatActions(ref, clock: _fixedClock),
);

Medication _med(String id, String name, {String dosage = '10 mg'}) =>
    Medication(
      id: id,
      name: name,
      dosage: dosage,
      route: MedicationRoute.oral,
    );

void main() {
  late HoldcloseDatabase db;
  late MedicationRepository repo;
  late AppointmentRepository apptRepo;
  late ProviderRepository providerRepo;
  late CareTasksRepository taskRepo;
  late CarePlanRepository carePlanRepo;
  late HealthLogRepository healthLogRepo;
  late ProviderContainer container;
  late Map<String, ChatActionExecutor> actions;

  setUp(() async {
    db = HoldcloseDatabase(NativeDatabase.memory());
    repo = MedicationRepository(db, clock: _fixedClock);
    apptRepo = AppointmentRepository(db);
    providerRepo = ProviderRepository(db);
    taskRepo = CareTasksRepository(db);
    carePlanRepo = CarePlanRepository(db);
    healthLogRepo = HealthLogRepository(db);
    final InMemoryStorageProvider storage = InMemoryStorageProvider();
    await storage.upsertPatient(maryHenderson());
    container = ProviderContainer(
      overrides: <Override>[
        medicationRepositoryProvider.overrideWithValue(repo),
        appointmentRepositoryProvider.overrideWithValue(apptRepo),
        providerRepositoryProvider.overrideWithValue(providerRepo),
        careTasksRepositoryProvider.overrideWithValue(taskRepo),
        carePlanRepositoryProvider.overrideWithValue(carePlanRepo),
        healthLogRepositoryProvider.overrideWithValue(healthLogRepo),
        storageProvider.overrideWithValue(storage),
      ],
    );
    actions = container.read(_actionsProvider);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('add_medication', () {
    test('a med with NO DOSE is refused OUT LOUD, not silently skipped '
        '(fb_1783968081885132)', () async {
      // The tester's report, verbatim: "I asked chat to add ibuprofen to
      // medications and it confirmed and navigated upon request. It wasn't
      // added." The model emitted add_medication without a `dosage`; the
      // executor bailed and returned null — which the service read as success,
      // so the confirm card said done and no medication existed. A coach that
      // claims a write it never made is worse than one that fails loudly: it
      // corrupts the caregiver's picture of their loved one's medications.
      //
      // The dose must come FROM THE CAREGIVER — inventing one would be a dosing
      // recommendation, which the coach must never make. So: ask, don't guess,
      // and never pretend.
      final ChatActionOutcome? outcome =
          await actions['add_medication']!(<String, String>{
        'name': 'Ibuprofen',
      });

      expect(outcome?.performed, isFalse,
          reason: 'nothing was written — the outcome must say so');
      expect(outcome?.failure, contains('Ibuprofen'));
      expect(outcome?.failure, contains('dose'));
      expect(await repo.listMedications(), isEmpty);
    });

    test('a med with no NAME is refused out loud too', () async {
      final ChatActionOutcome? outcome =
          await actions['add_medication']!(<String, String>{'dosage': '200 mg'});

      expect(outcome?.performed, isFalse);
      expect(outcome?.failure, isNotNull);
      expect(await repo.listMedications(), isEmpty);
    });

    test('windows are CREATED when the caregiver has none — and the coach says '
        'what times it assumed (fb: "The time windows were not added")',
        () async {
      // The report, verbatim: "The time windows were not added." They weren't:
      // _attachMedicationWindows only MATCHED existing windows, and every new
      // install has ZERO (the seeded defaults were dropped at v15). So it
      // silently attached nothing while the coach said it had scheduled the
      // medication. A caregiver could never schedule a med through chat at all.
      final ChatActionOutcome? outcome =
          await actions['add_medication']!(<String, String>{
        'name': 'Ibuprofen',
        'dosage': '400 mg',
        'windows': 'morning, evening',
      });

      expect(outcome?.performed, isTrue);

      // The windows now exist...
      final List<DoseWindow> windows =
          await repo.windowsForPatient(maryHenderson().id);
      expect(
        windows.map((DoseWindow w) => w.label),
        containsAll(<String>['Morning', 'Evening']),
      );
      // ...and the medication is actually IN them.
      final List<MedicationWindowEntry> entries =
          await repo.entriesForMedication(
              (await repo.listMedications()).single.id);
      expect(entries, hasLength(2));

      // ...and the coach DISCLOSES the times it assumed, so they can be fixed.
      expect(outcome?.notice, contains('8:00 AM'));
      expect(outcome?.notice, contains('6:00 PM'));
      expect(outcome?.notice, contains('Dose windows'));
    });

    test('an existing window is reused, not duplicated, and needs no notice',
        () async {
      await repo.upsertWindow(DoseWindow(
        id: 'w-morning',
        patientId: maryHenderson().id,
        label: 'Morning',
        anchorTime: const TimeOfDay(hour: 7, minute: 30),
        sortOrder: 0,
      ));

      final ChatActionOutcome? outcome =
          await actions['add_medication']!(<String, String>{
        'name': 'Lisinopril',
        'dosage': '10 mg',
        'windows': 'morning',
      });

      expect(outcome?.performed, isTrue);
      final List<DoseWindow> windows =
          await repo.windowsForPatient(maryHenderson().id);
      expect(windows, hasLength(1), reason: 'the caregiver\'s own window, kept');
      expect(windows.single.anchorTime?.hour, 7,
          reason: 'their 7:30 time must not be overwritten');
      expect(outcome?.notice, isNull,
          reason: 'nothing was assumed — nothing to disclose');
    });

    test('a window word we do not recognise is reported, not silently dropped',
        () async {
      final ChatActionOutcome? outcome =
          await actions['add_medication']!(<String, String>{
        'name': 'Metformin',
        'dosage': '500 mg',
        'windows': 'whenever the moon is full',
      });

      expect(outcome?.performed, isTrue, reason: 'the medication still landed');
      expect(outcome?.notice, contains("couldn't match"));
      expect(await repo.windowsForPatient(maryHenderson().id), isEmpty);
    });

    test('an EXISTING medication can be scheduled into windows '
        '(fb: "Still no timeframes added")', () async {
      // The second report, after a fix that only covered the ADD path:
      // "Still no timeframes added". The caregiver already had Ibuprofen and
      // asked to put it in morning + evening — but `windows` existed ONLY on
      // add_medication, so no action could carry the request. Nothing happened,
      // and the coach said it had. Verified on the device: 1 medication,
      // 0 dose_windows, 0 entries.
      await actions['add_medication']!(<String, String>{
        'name': 'Ibuprofen',
        'dosage': '400 mg',
      });

      final ChatActionOutcome? outcome =
          await actions['update_medication']!(<String, String>{
        'name': 'Ibuprofen',
        'windows': 'morning, evening',
      });

      expect(outcome?.performed, isTrue);
      final List<DoseWindow> windows =
          await repo.windowsForPatient(maryHenderson().id);
      expect(
        windows.map((DoseWindow w) => w.label),
        containsAll(<String>['Morning', 'Evening']),
      );
      final Medication med = (await repo.listMedications()).single;
      expect(await repo.entriesForMedication(med.id), hasLength(2),
          reason: 'the medication must actually BE in those windows');
      expect(outcome?.notice, contains('8:00 AM'));
    });

    test('scheduling the same medication into the same window twice does not '
        'duplicate it', () async {
      await actions['add_medication']!(<String, String>{
        'name': 'Ibuprofen',
        'dosage': '400 mg',
        'windows': 'morning',
      });
      // The caregiver asks again (or the model repeats itself).
      await actions['update_medication']!(<String, String>{
        'name': 'Ibuprofen',
        'windows': 'morning',
      });

      final Medication med = (await repo.listMedications()).single;
      expect(await repo.entriesForMedication(med.id), hasLength(1),
          reason: 'a med listed twice in one window reads as two doses');
      expect(await repo.windowsForPatient(maryHenderson().id), hasLength(1));
    });

    test('records a med the caregiver named, with route + prescriber',
        () async {
      final ChatActionOutcome? outcome =
          await actions['add_medication']!(<String, String>{
        'name': 'Donepezil',
        'dosage': '10 mg',
        'route': 'oral',
        'prescriber': 'Dr. Ortega',
        'notes': 'with breakfast',
      });

      // Mutations are prose-confirmed — no citation chip — but the outcome
      // must still report that the write LANDED. (Before 2026-07-13 an
      // executor returned null both on success and when it silently bailed,
      // so a no-op was indistinguishable from a save.)
      expect(outcome?.performed, isTrue);
      expect(outcome?.citation, isNull);
      final List<Medication> meds = await repo.listMedications();
      expect(meds, hasLength(1));
      final Medication m = meds.single;
      expect(m.name, 'Donepezil');
      expect(m.dosage, '10 mg');
      expect(m.route, MedicationRoute.oral);
      expect(m.prescriber, 'Dr. Ortega');
      expect(m.notes, 'with breakfast');
    });

    test('defaults the route to oral and leaves optional fields null',
        () async {
      await actions['add_medication']!(<String, String>{
        'name': 'Metformin',
        'dosage': '500 mg',
      });
      final Medication m = (await repo.listMedications()).single;
      expect(m.route, MedicationRoute.oral);
      expect(m.prescriber, isNull);
      expect(m.notes, isNull);
    });

    test('is a no-op without a name or dosage (never fabricate a med)',
        () async {
      await actions['add_medication']!(<String, String>{'name': 'Aspirin'});
      await actions['add_medication']!(<String, String>{'dosage': '5 mg'});
      expect(await repo.listMedications(), isEmpty);
    });

    test('parses the injection route', () async {
      await actions['add_medication']!(<String, String>{
        'name': 'Insulin',
        'dosage': '10 units',
        'route': 'injection',
      });
      expect((await repo.listMedications()).single.route,
          MedicationRoute.injection);
    });

    test('schedules the med into the named dose windows', () async {
      final String patientId = maryHenderson().id;
      await repo.upsertWindow(DoseWindow(
          id: 'w-morning',
          patientId: patientId,
          label: 'Morning',
          anchorTime: const TimeOfDay(hour: 8, minute: 0),
          sortOrder: 0));
      await repo.upsertWindow(DoseWindow(
          id: 'w-noon',
          patientId: patientId,
          label: 'Noon',
          anchorTime: const TimeOfDay(hour: 12, minute: 0),
          sortOrder: 1));
      await repo.upsertWindow(DoseWindow(
          id: 'w-evening',
          patientId: patientId,
          label: 'Evening',
          anchorTime: const TimeOfDay(hour: 18, minute: 0),
          sortOrder: 2));

      await actions['add_medication']!(<String, String>{
        'name': 'Plestavier',
        'dosage': '250 mg',
        'windows': 'morning, evening',
      });

      final List<Medication> meds = await repo.listMedications();
      expect(meds, hasLength(1));
      final List<MedicationWindowEntry> entries =
          await repo.entriesForMedication(meds.single.id);
      // Morning + evening attached; noon left out.
      expect(entries.map((MedicationWindowEntry e) => e.windowId).toSet(),
          <String>{'w-morning', 'w-evening'});
    });

    test('unknown window names are skipped, the med still records', () async {
      await repo.upsertWindow(DoseWindow(
          id: 'w-morning',
          patientId: maryHenderson().id,
          label: 'Morning',
          anchorTime: const TimeOfDay(hour: 8, minute: 0),
          sortOrder: 0));

      await actions['add_medication']!(<String, String>{
        'name': 'Plestavier',
        'dosage': '250 mg',
        'windows': 'midnight',
      });

      final Medication med = (await repo.listMedications()).single;
      expect(await repo.entriesForMedication(med.id), isEmpty);
    });
  });

  group('update_medication', () {
    test('changes the dosage of the med resolved by name (same row)',
        () async {
      await repo.upsertMedication(_med('m1', 'Donepezil'));
      await actions['update_medication']!(<String, String>{
        'name': 'donepezil', // case-insensitive resolve
        'dosage': '5 mg',
      });
      final Medication m = (await repo.listMedications()).single;
      expect(m.id, 'm1'); // upsert, not a new row
      expect(m.dosage, '5 mg');
      expect(m.name, 'Donepezil'); // untouched fields preserved
    });

    test('renames via new_name', () async {
      await repo.upsertMedication(_med('m1', 'Tylenol'));
      await actions['update_medication']!(<String, String>{
        'name': 'Tylenol',
        'new_name': 'Acetaminophen',
      });
      expect((await repo.listMedications()).single.name, 'Acetaminophen');
    });

    test('is a no-op when the name resolves to nothing', () async {
      await repo.upsertMedication(_med('m1', 'Aspirin'));
      await actions['update_medication']!(<String, String>{
        'name': 'Nonexistent',
        'dosage': '1 mg',
      });
      expect((await repo.listMedications()).single.dosage, '10 mg');
    });
  });

  group('delete_medication', () {
    test('removes the med resolved by name', () async {
      await repo.upsertMedication(_med('m1', 'Ibuprofen'));
      await actions['delete_medication']!(<String, String>{
        'name': 'Ibuprofen',
      });
      expect(await repo.listMedications(), isEmpty);
    });

    test('is a no-op for an unknown name', () async {
      await repo.upsertMedication(_med('m1', 'Aspirin'));
      await actions['delete_medication']!(<String, String>{'name': 'Xyz'});
      expect(await repo.listMedications(), hasLength(1));
    });

    test('does not delete on an ambiguous partial match', () async {
      await repo.upsertMedication(_med('m1', 'Vitamin D'));
      await repo.upsertMedication(_med('m2', 'Vitamin B12'));
      // "Vitamin" matches both — resolver bails rather than guess.
      await actions['delete_medication']!(<String, String>{'name': 'Vitamin'});
      expect(await repo.listMedications(), hasLength(2));
    });
  });

  group('resolveOccurredAt', () {
    final DateTime now = DateTime(2026, 6, 4, 16);
    test('"just now" and blank map to now', () {
      expect(resolveOccurredAt('just now', now), now);
      expect(resolveOccurredAt('', now), now);
      expect(resolveOccurredAt(null, now), now);
    });
    test('"yesterday" lands mid-day the day before', () {
      expect(resolveOccurredAt('yesterday afternoon', now),
          DateTime(2026, 6, 3, 14));
    });
    test('"last night" lands at 9pm the day before', () {
      expect(resolveOccurredAt('last night', now), DateTime(2026, 6, 3, 21));
    });
  });

  group('add_appointment — relative dates (resolved in Dart)', () {
    // _fixedClock is Thursday 2026-06-04 09:00. The 70b model mangles absolute
    // dates it has to compute ("2026-0712:00"), so it passes relative WORDS and
    // the app does the arithmetic deterministically (2026-07-14).
    Future<Appointment> schedule(String startsAt) async {
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. Ortega',
        'starts_at': startsAt,
      });
      final List<Appointment> appts = await apptRepo.listAppointments();
      return appts.last;
    }

    test('"tomorrow 12:00" → the next day at noon', () async {
      expect((await schedule('tomorrow 12:00')).startsAt,
          DateTime(2026, 6, 5, 12, 0));
    });

    test('"tomorrow at noon" → noon keyword', () async {
      expect((await schedule('tomorrow at noon')).startsAt,
          DateTime(2026, 6, 5, 12, 0));
    });

    test('"today 3:30 pm" → same day, 12-hour meridiem', () async {
      expect((await schedule('today 3:30 pm')).startsAt,
          DateTime(2026, 6, 4, 15, 30));
    });

    test('"day after tomorrow 9am"', () async {
      expect((await schedule('day after tomorrow 9am')).startsAt,
          DateTime(2026, 6, 6, 9, 0));
    });

    test('a weekday name rolls forward to its NEXT occurrence', () async {
      // Thursday 06-04 → "monday" is 06-08.
      expect((await schedule('monday 09:00')).startsAt,
          DateTime(2026, 6, 8, 9, 0));
    });

    test('an absolute ISO date still works', () async {
      expect((await schedule('2026-08-03 14:30')).startsAt,
          DateTime(2026, 8, 3, 14, 30));
    });

    test('a relative day with NO time does not guess — visit is refused',
        () async {
      final ChatActionOutcome? out =
          await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. Ortega',
        'starts_at': 'sometime tomorrow',
      });
      expect(out?.performed, isFalse);
    });
  });

  group('add_appointment', () {
    test('schedules a visit, creating the named clinician when new',
        () async {
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. Ortega',
        'starts_at': '2026-06-10 14:30',
        'duration_minutes': '45',
        'location': 'Neurology clinic',
        'agenda': 'Med review; Balance check',
      });

      final List<Appointment> appts = await apptRepo.listAppointments();
      expect(appts, hasLength(1));
      final Appointment a = appts.single;
      expect(a.startsAt, DateTime(2026, 6, 10, 14, 30));
      expect(a.durationMinutes, 45);
      expect(a.location, 'Neurology clinic');
      expect(a.agenda, <String>['Med review', 'Balance check']);
      expect(a.status, AppointmentStatus.upcoming);
      final provs = await providerRepo.listProviders();
      expect(provs.where((p) => p.name == 'Dr. Ortega'), hasLength(1));
      expect(a.providerId,
          provs.firstWhere((p) => p.name == 'Dr. Ortega').id);
    });

    test('reuses an existing clinician rather than duplicating', () async {
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. Patel',
        'starts_at': '2026-06-10 09:00',
      });
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. Patel',
        'starts_at': '2026-06-12 09:00',
      });
      expect(
          (await providerRepo.listProviders())
              .where((p) => p.name == 'Dr. Patel'),
          hasLength(1));
      expect(await apptRepo.listAppointments(), hasLength(2));
    });

    test('is a no-op without a clinician or a parseable time', () async {
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. X',
      });
      await actions['add_appointment']!(<String, String>{
        'starts_at': '2026-06-10 09:00',
      });
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. X',
        'starts_at': 'sometime soon',
      });
      expect(await apptRepo.listAppointments(), isEmpty);
    });
  });

  group('update_appointment / cancel_appointment', () {
    test('reschedules the upcoming visit matched by clinician name',
        () async {
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. Ortega',
        'starts_at': '2026-06-10 14:30',
        'location': 'Clinic A',
      });
      await actions['update_appointment']!(<String, String>{
        'provider_name': 'Ortega', // substring match
        'starts_at': '2026-06-11 09:00',
      });
      final Appointment a = (await apptRepo.listAppointments()).single;
      expect(a.startsAt, DateTime(2026, 6, 11, 9, 0));
      expect(a.location, 'Clinic A'); // untouched
    });

    test('cancel flips status to canceled but keeps the row', () async {
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. Ortega',
        'starts_at': '2026-06-10 14:30',
      });
      await actions['cancel_appointment']!(<String, String>{
        'provider_name': 'Dr. Ortega',
      });
      final Appointment a = (await apptRepo.listAppointments()).single;
      expect(a.status, AppointmentStatus.canceled);
    });

    test('cancel is a no-op for an unknown clinician', () async {
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. Ortega',
        'starts_at': '2026-06-10 14:30',
      });
      await actions['cancel_appointment']!(<String, String>{
        'provider_name': 'Nobody',
      });
      expect((await apptRepo.listAppointments()).single.status,
          AppointmentStatus.upcoming);
    });
  });

  group('care tasks', () {
    test('add_task creates a task for the loved one', () async {
      await actions['add_task']!(<String, String>{
        'title': 'Pick up prescription',
        'body': 'CVS on Main',
        'due_at': '2026-06-10 17:00',
      });
      final List<CareTask> tasks = await taskRepo.listTasks();
      expect(tasks, hasLength(1));
      final CareTask t = tasks.single;
      expect(t.title, 'Pick up prescription');
      expect(t.body, 'CVS on Main');
      expect(t.dueAt, DateTime(2026, 6, 10, 17, 0));
      expect(t.patientId, maryHenderson().id);
      expect(t.completedAt, isNull);
    });

    test('add_task is a no-op without a title', () async {
      await actions['add_task']!(<String, String>{'body': 'orphan'});
      expect(await taskRepo.listTasks(), isEmpty);
    });

    test('complete_task marks the resolved task done', () async {
      await actions['add_task']!(<String, String>{'title': 'Call insurance'});
      await actions['complete_task']!(<String, String>{
        'title': 'Call insurance',
      });
      expect((await taskRepo.listTasks()).single.completedAt, isNotNull);
    });

    test('delete_task removes the resolved task', () async {
      await actions['add_task']!(<String, String>{'title': 'Order supplies'});
      await actions['delete_task']!(<String, String>{
        'title': 'Order supplies',
      });
      expect(await taskRepo.listTasks(), isEmpty);
    });
  });

  group('add_routine', () {
    test('creates a daily routine for the loved one', () async {
      await actions['add_routine']!(<String, String>{
        'name': 'Morning hygiene',
        'body': 'Brush teeth, wash face',
        'time': '07:30',
        'frequency': 'daily',
      });
      final List<CarePlanRoutine> routines = await carePlanRepo.listAll();
      expect(routines, hasLength(1));
      final CarePlanRoutine r = routines.single;
      expect(r.title, 'Morning hygiene');
      expect(r.body, 'Brush teeth, wash face');
      expect(r.scheduledTime, const TimeOfDay(hour: 7, minute: 30));
      expect(r.frequencyKind, FrequencyKind.daily);
      expect(r.daysOfWeek, isEmpty);
      expect(r.patientId, maryHenderson().id);
    });

    test('a weekly routine carries the named days', () async {
      await actions['add_routine']!(<String, String>{
        'name': 'Physical therapy',
        'time': '10:00',
        'frequency': 'weekly',
        'days': 'Mon, Wed, Fri',
      });
      final CarePlanRoutine r = (await carePlanRepo.listAll()).single;
      expect(r.frequencyKind, FrequencyKind.weekly);
      expect(r.daysOfWeek, <int>{1, 3, 5});
    });

    test('is a no-op without a name or a parseable time', () async {
      await actions['add_routine']!(<String, String>{'time': '08:00'});
      await actions['add_routine']!(<String, String>{'name': 'Walk'});
      await actions['add_routine']!(<String, String>{
        'name': 'Walk',
        'time': 'after lunch', // not HH:MM
      });
      expect(await carePlanRepo.listAll(), isEmpty);
    });
  });

  group('add_health_log', () {
    test('records a vitals entry the caregiver stated', () async {
      await actions['add_health_log']!(<String, String>{
        'kind': 'vitals',
        'value': 'Blood pressure 128 over 82',
        'recorded_at': 'this morning',
      });
      final List<HealthLogEntry> entries = await healthLogRepo.listAll();
      expect(entries, hasLength(1));
      final HealthLogEntry e = entries.single;
      expect(e.kind, HealthLogKind.vitals);
      expect(e.notes, 'Blood pressure 128 over 82');
      expect(e.patientId, maryHenderson().id);
      // "this morning" resolves to 9am on the fixed clock's day.
      expect(e.recordedAt, DateTime(2026, 6, 4, 9));
    });

    test('defaults the kind to note and accepts a note arg', () async {
      await actions['add_health_log']!(<String, String>{
        'note': 'Slept poorly last night',
      });
      final HealthLogEntry e = (await healthLogRepo.listAll()).single;
      expect(e.kind, HealthLogKind.note);
      expect(e.notes, 'Slept poorly last night');
    });

    test('is a no-op without a value or note', () async {
      await actions['add_health_log']!(<String, String>{'kind': 'symptom'});
      expect(await healthLogRepo.listAll(), isEmpty);
    });

    test('stores a weight_lbs reading as a structured vitals field',
        () async {
      await actions['add_health_log']!(<String, String>{
        'kind': 'vitals',
        'weight_lbs': '182.5',
        'recorded_at': 'this morning',
      });
      final HealthLogEntry e = (await healthLogRepo.listAll()).single;
      expect(e.kind, HealthLogKind.vitals);
      expect(e.weightLbs, 182.5);
      // The reading is structured, not a notes dump (fb_1781115352788931).
      expect(e.notes, isNull);
    });

    test('keeps both the weight and the free-text value when given both',
        () async {
      await actions['add_health_log']!(<String, String>{
        'kind': 'vitals',
        'weight_lbs': '182.5',
        'value': 'Weighed after breakfast',
      });
      final HealthLogEntry e = (await healthLogRepo.listAll()).single;
      expect(e.weightLbs, 182.5);
      expect(e.notes, 'Weighed after breakfast');
    });

    test('is a no-op for a garbage weight_lbs with no value', () async {
      await actions['add_health_log']!(<String, String>{
        'kind': 'vitals',
        'weight_lbs': 'a lot',
      });
      expect(await healthLogRepo.listAll(), isEmpty);
    });
  });

  group('log_dose', () {
    test('records a taken dose for the medication resolved by name',
        () async {
      await repo.upsertMedication(_med('m1', 'Donepezil'));
      await actions['log_dose']!(<String, String>{
        'name': 'donepezil', // case-insensitive resolve
        'outcome': 'taken',
        'time': '2026-06-04 08:00',
      });
      final List<DoseLog> logs = await repo.logsFor('m1');
      expect(logs, hasLength(1));
      final DoseLog l = logs.single;
      expect(l.status, DoseStatus.taken);
      expect(l.scheduledFor, DateTime(2026, 6, 4, 8, 0));
      expect(l.takenAt, DateTime(2026, 6, 4, 8, 0));
    });

    test('a skipped dose leaves takenAt null', () async {
      await repo.upsertMedication(_med('m1', 'Metformin'));
      await actions['log_dose']!(<String, String>{
        'name': 'Metformin',
        'outcome': 'skipped',
        'time': 'just now',
      });
      final DoseLog l = (await repo.logsFor('m1')).single;
      expect(l.status, DoseStatus.skipped);
      expect(l.takenAt, isNull);
    });

    test('is a no-op when the medication name resolves to nothing', () async {
      await repo.upsertMedication(_med('m1', 'Aspirin'));
      await actions['log_dose']!(<String, String>{
        'name': 'Nonexistent',
        'outcome': 'taken',
      });
      expect(await repo.logsFor('m1'), isEmpty);
    });
  });

  group('navigate', () {
    test('parks the route for a known target', () async {
      await actions['navigate']!(<String, String>{'target': 'calendar'});
      expect(container.read(chatNavigateRequestProvider), '/team/calendar');
    });

    test('maps the friendly target keywords to routes', () async {
      const Map<String, String> cases = <String, String>{
        'home': '/',
        'medical': '/medical',
        'medications': '/medications',
        'meds': '/medications',
        'team': '/team',
        'tasks': '/team/tasks',
        'journal': '/journal',
        'community': '/community',
        'emergency': '/medical/cards/emergency',
      };
      for (final MapEntry<String, String> e in cases.entries) {
        container.read(chatNavigateRequestProvider.notifier).clear();
        await actions['navigate']!(<String, String>{'target': e.key});
        expect(container.read(chatNavigateRequestProvider), e.value,
            reason: e.key);
      }
    });

    test('an unknown target is a no-op', () async {
      await actions['navigate']!(<String, String>{'target': 'spaceship'});
      expect(container.read(chatNavigateRequestProvider), isNull);
    });

    test('target=appointment deep-links to the visit, else the calendar',
        () async {
      // No matching visit yet → fall back to the calendar.
      await actions['navigate']!(<String, String>{
        'target': 'appointment',
        'provider_name': 'Dr. Simes',
      });
      expect(container.read(chatNavigateRequestProvider), '/team/calendar');

      // Create one, then it deep-links to that appointment.
      await actions['add_appointment']!(<String, String>{
        'provider_name': 'Dr. Simes',
        'starts_at': '2026-06-05 13:00',
      });
      container.read(chatNavigateRequestProvider.notifier).clear();
      await actions['navigate']!(<String, String>{
        'target': 'appointment',
        'provider_name': 'Simes',
      });
      expect(container.read(chatNavigateRequestProvider),
          startsWith('/appointments/'));
    });

    test('an ISO date on the calendar opens that day', () async {
      await actions['navigate']!(<String, String>{
        'target': 'calendar',
        'date': '2026-06-18',
      });
      expect(container.read(chatNavigateRequestProvider),
          '/team/calendar?date=2026-06-18');
    });

    test('a "Month Day" date resolves against the app year', () async {
      await actions['navigate']!(<String, String>{
        'target': 'schedule', // also routes to the calendar
        'date': 'June 18th',
      });
      // _fixedClock() is 2026, so the bare month/day lands in 2026.
      expect(container.read(chatNavigateRequestProvider),
          '/team/calendar?date=2026-06-18');
    });
  });

  group('parseCalendarDate', () {
    final DateTime now = DateTime(2026, 6, 4);
    test('ISO date', () {
      expect(parseCalendarDate('2026-06-18', now), DateTime(2026, 6, 18));
    });
    test('"Month Day" / "Mon Dayth" / "Day Month"', () {
      expect(parseCalendarDate('June 18', now), DateTime(2026, 6, 18));
      expect(parseCalendarDate('Jun 18th', now), DateTime(2026, 6, 18));
      expect(parseCalendarDate('18 June', now), DateTime(2026, 6, 18));
    });
    test('numeric M/D and M-D', () {
      expect(parseCalendarDate('6/18', now), DateTime(2026, 6, 18));
      expect(parseCalendarDate('6-18', now), DateTime(2026, 6, 18));
    });
    test('blank / unparseable / null → null', () {
      expect(parseCalendarDate('', now), isNull);
      expect(parseCalendarDate('sometime next week', now), isNull);
      expect(parseCalendarDate(null, now), isNull);
    });
  });
}

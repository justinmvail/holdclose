import 'dart:io';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/main.dart';
import 'package:holdclose/models/care_event.dart';
import 'package:holdclose/models/care_shift.dart';
import 'package:holdclose/models/care_task.dart';
import 'package:holdclose/models/expense.dart';
import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/models/patient.dart';
import 'package:holdclose/models/settings.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/expenses_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

DateTime _fixedClock() => DateTime.utc(2026, 5, 29, 19, 0);

JournalEntry _preexistingEntry() => JournalEntry(
      id: 'pre-existing-entry',
      createdAt: _fixedClock(),
      occurredAt: _fixedClock(),
      situationText: 'carried-over situation',
      attemptsText: 'carried-over attempt',
      notes: 'carried-over note',
    );

Patient _patient(String id, String name) => Patient(
      id: id,
      name: name,
      age: 70,
      diagnosis: 'unspecified',
      diagnosedAt: DateTime.utc(2023, 1, 1),
      medications: const <CrisisMedication>[],
      allergies: const <String>[],
      calms: const <String>[],
      escalates: const <String>[],
      primaryCaregiver: const Contact(name: 'Caregiver', phone: '555-0000'),
      healthcarePOA: const Contact(name: 'POA', phone: '555-0001'),
      advanceDirective: const AdvanceDirectiveStatus(
        onFileAt: 'Unknown',
        dnr: false,
      ),
    );

Patient _preexistingPatient() => _patient('pre-existing-patient', 'Someone Else');

({ProviderContainer container, InMemoryStorageProvider storage}) _build({
  required bool resetOnLaunch,
  bool withPatient = true,
}) {
  // Pin "now" to the fixtures' era so the 30-day journal window includes the
  // seeded + demo entries regardless of the host's real clock.
  final InMemoryStorageProvider storage =
      InMemoryStorageProvider(clock: _fixedClock);
  addTearDown(storage.dispose);
  // Pre-populate so the "state survives" assertions have something to
  // assert against — and so the "reset wiped it" assertions can verify
  // by absence after a reset run.
  storage.updateSettings(
    AppSettings.defaults().copyWith(resetOnLaunchDemo: resetOnLaunch),
  );
  if (withPatient) {
    storage.upsertPatient(_preexistingPatient());
  }
  storage.insertJournalEntry(_preexistingEntry());

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      storageBackendProvider.overrideWithValue(storage),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, storage: storage);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('maybeResetForDemo — BUILD_SPEC.md §9.3 + Task 26', () {
    test('with demoMode && resetOnLaunchDemo: resets storage AND populates '
        'the seed', () async {
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build(resetOnLaunch: true);

      await maybeResetForDemo(built.container, demoMode: true);

      // Pre-existing patient is gone — replaced by Mary Henderson.
      final Patient? patient = await built.storage.getPatient();
      expect(patient, isNotNull);
      expect(patient!.id, 'demo-patient-mary');

      // Pre-existing journal entry is gone — replaced by the 6 seed
      // entries.
      final List<JournalEntry> entries = await built.storage
          .watchJournalEntries(window: const Duration(days: 30))
          .first;
      expect(entries, hasLength(6));
      expect(
        entries.where((JournalEntry e) => e.id == 'pre-existing-entry'),
        isEmpty,
      );
    });

    test('with demoMode but resetOnLaunchDemo OFF: state survives untouched',
        () async {
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build(resetOnLaunch: false);

      await maybeResetForDemo(built.container, demoMode: true);

      final Patient? patient = await built.storage.getPatient();
      expect(patient, isNotNull);
      expect(patient!.id, 'pre-existing-patient');

      final List<JournalEntry> entries = await built.storage
          .watchJournalEntries(window: const Duration(days: 30))
          .first;
      expect(entries, hasLength(1));
      expect(entries.single.id, 'pre-existing-entry');
    });

    test('with demoMode, resetOnLaunchDemo OFF, no loved one on file: '
        'Mary is backfilled without touching other data', () async {
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build(resetOnLaunch: false, withPatient: false);

      // The bug: with reset off the seed never ran, so a store can hold
      // the caregiver's journal/medication data but no patient — and the
      // Emergency Card then gates on a missing loved one.
      expect(await built.storage.getPatient(), isNull);

      await maybeResetForDemo(built.container, demoMode: true);

      // Mary is now present so patient-dependent screens work...
      final Patient? patient = await built.storage.getPatient();
      expect(patient, isNotNull);
      expect(patient!.id, 'demo-patient-mary');

      // ...but the backfill is non-destructive — the pre-existing journal
      // entry is left exactly as it was (no reset, no extra seed entries).
      final List<JournalEntry> entries = await built.storage
          .watchJournalEntries(window: const Duration(days: 30))
          .first;
      expect(entries, hasLength(1));
      expect(entries.single.id, 'pre-existing-entry');
    });

    test('without demoMode: even when resetOnLaunchDemo is ON, state survives',
        () async {
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build(resetOnLaunch: true);

      await maybeResetForDemo(built.container, demoMode: false);

      final Patient? patient = await built.storage.getPatient();
      expect(patient, isNotNull);
      expect(patient!.id, 'pre-existing-patient');

      final List<JournalEntry> entries = await built.storage
          .watchJournalEntries(window: const Duration(days: 30))
          .first;
      expect(entries, hasLength(1));
      expect(entries.single.id, 'pre-existing-entry');
    });
  });

  group('maybeRestampCareCirclePatient — multi-patient migration (Issue #6)',
      () {
    late HoldcloseDatabase db;
    late CareTasksRepository tasksRepo;
    late CareShiftsRepository shiftsRepo;
    late ExpensesRepository expensesRepo;
    late CareEventsRepository eventsRepo;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      db = HoldcloseDatabase(NativeDatabase.memory());
      tasksRepo = CareTasksRepository(db);
      shiftsRepo = CareShiftsRepository(db);
      expensesRepo = ExpensesRepository(db);
      eventsRepo = CareEventsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    CareTask legacyTask(String id, {String patientId = 'demo-patient-mary'}) =>
        CareTask(id: id, title: 'Task $id', patientId: patientId);

    CareShift legacyShift(String id,
            {String patientId = 'demo-patient-mary'}) =>
        CareShift(
          id: id,
          caregiverId: 'c1',
          start: DateTime.utc(2026, 6, 1, 9),
          end: DateTime.utc(2026, 6, 1, 17),
          patientId: patientId,
        );

    Expense legacyExpense(String id,
            {String patientId = 'demo-patient-mary'}) =>
        Expense(
          id: id,
          amountCents: 500,
          description: 'Expense $id',
          paidByCaregiverId: 'c1',
          paidAt: DateTime.utc(2026, 6, 1, 9),
          kind: ExpenseKind.meds,
          patientId: patientId,
        );

    CareEvent legacyNote(String id, {String patientId = 'demo-patient-mary'}) =>
        CareEvent(
          id: id,
          kind: CareEventKind.note,
          title: 'Note $id',
          start: DateTime.utc(2026, 6, 1, 9),
          patientId: patientId,
        );

    /// Build a container whose four care-circle repo providers point at the
    /// SAME in-memory DB the test seeds, and whose storage holds [activeId]
    /// as the active loved one (so activePatientIdProvider resolves to it).
    ProviderContainer makeContainer(String activeId) {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      storage.upsertPatient(_patient(activeId, 'Active Person'));
      storage.setActivePatientId(activeId);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageBackendProvider.overrideWithValue(storage),
          careTasksRepositoryProvider.overrideWithValue(tasksRepo),
          careShiftsRepositoryProvider.overrideWithValue(shiftsRepo),
          expensesRepositoryProvider.overrideWithValue(expensesRepo),
          careEventsRepositoryProvider.overrideWithValue(eventsRepo),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('re-stamps every legacy demo-patient-mary row onto the active loved '
        'one', () async {
      // Seed legacy rows under the old hardcoded id across all four tables.
      await tasksRepo.upsertTask(legacyTask('t1'));
      await shiftsRepo.upsertShift(legacyShift('s1'));
      await expensesRepo.upsertExpense(legacyExpense('e1'));
      await eventsRepo.upsertEvent(legacyNote('n1'));

      const String activeId = 'patient-bob';
      final ProviderContainer container = makeContainer(activeId);

      final bool ran = await maybeRestampCareCirclePatient(container);
      expect(ran, isTrue);

      // Every row now belongs to the active loved one; none remain under the
      // legacy id.
      expect(await tasksRepo.listTasksForPatient('demo-patient-mary'), isEmpty);
      expect(
        (await tasksRepo.listTasksForPatient(activeId)).single.id,
        't1',
      );
      expect(
        (await shiftsRepo.listShiftsForPatient(activeId)).single.id,
        's1',
      );
      expect(
        (await expensesRepo.listExpensesForPatient(activeId)).single.id,
        'e1',
      );
      expect(
        (await eventsRepo.listEventsForPatient(activeId)).single.id,
        'n1',
      );

      // The guard is set, so a second invocation is a no-op (returns false)
      // and doesn't touch the now-correct rows.
      final bool reran = await maybeRestampCareCirclePatient(container);
      expect(reran, isFalse);
      expect(
        (await tasksRepo.listTasksForPatient(activeId)).single.id,
        't1',
      );
    });

    test('is a harmless no-op when the active loved one IS demo-patient-mary',
        () async {
      await tasksRepo.upsertTask(legacyTask('t1'));
      final ProviderContainer container = makeContainer('demo-patient-mary');

      // Runs (guard gets set) but moves nothing — from == to.
      final bool ran = await maybeRestampCareCirclePatient(container);
      expect(ran, isTrue);
      expect(
        (await tasksRepo.listTasksForPatient('demo-patient-mary')).single.id,
        't1',
      );
    });

    test('holds off (does not burn the guard) when no loved one is on file',
        () async {
      await tasksRepo.upsertTask(legacyTask('t1'));
      // Storage with NO patient — activePatientIdProvider falls back to
      // demo-patient-mary, but there's no real target person yet.
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageBackendProvider.overrideWithValue(storage),
          careTasksRepositoryProvider.overrideWithValue(tasksRepo),
          careShiftsRepositoryProvider.overrideWithValue(shiftsRepo),
          expensesRepositoryProvider.overrideWithValue(expensesRepo),
          careEventsRepositoryProvider.overrideWithValue(eventsRepo),
        ],
      );
      addTearDown(container.dispose);

      final bool ran = await maybeRestampCareCirclePatient(container);
      expect(ran, isFalse);

      // Because the guard wasn't set, the migration gets another chance once
      // a patient exists.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(careCircleRestampPrefsKey), isNull);
    });
  });

  group('CrashLog — on-device, user-initiated crash capture', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('crashlog_');
      CrashLog.instance.overrideDir = tmp;
    });

    tearDown(() async {
      CrashLog.instance.overrideDir = null;
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('record persists the message + stack; read returns it', () async {
      expect(await CrashLog.instance.read(), isEmpty);

      await CrashLog.instance.record('Uncaught: boom', StackTrace.current);

      final String snapshot = await CrashLog.instance.read();
      expect(snapshot, contains('Uncaught: boom'));
      // The crash file lands under the overridden dir.
      expect(File(p.join(tmp.path, CrashLog.fileName)).existsSync(), isTrue);
    });

    test('clear drops the crash file so it is not re-offered', () async {
      await CrashLog.instance.record('Uncaught: once', StackTrace.current);
      expect(await CrashLog.instance.read(), isNotEmpty);

      await CrashLog.instance.clear();
      expect(await CrashLog.instance.read(), isEmpty);
    });

    test('the file is capped so a crash loop can never grow it unbounded',
        () async {
      // Write well past the cap; the freshest tail must survive.
      for (int i = 0; i < 2000; i++) {
        await CrashLog.instance.record('Uncaught: crash #$i', StackTrace.current);
      }
      final int len =
          await File(p.join(tmp.path, CrashLog.fileName)).length();
      expect(len, lessThanOrEqualTo(CrashLog.maxBytes));
      // The most recent entry is retained.
      expect(await CrashLog.instance.read(), contains('crash #1999'));
    });
  });
}

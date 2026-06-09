import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

void main() {
  // ---- Shared fixtures -----------------------------------------------------

  JournalEntry buildEntry({
    String id = 'entry-001',
    String behaviorId = 'sundowning',
    JournalOutcome outcome = JournalOutcome.positive,
    DateTime? createdAt,
    String? notes,
    String? voiceNotePath,
    String? photoPath,
    int attempt = 1,
  }) =>
      JournalEntry(
        id: id,
        behavior: Behavior.byId(behaviorId)!,
        triage: const TriageAnswers(
          when: TriageWhen.lateAfternoonEvening,
          whatChanged: TriageWhatChanged.nothing,
          whatTried: TriageWhatTried.talked,
        ),
        result: DecoderResult(
          say: const <String>[
            "That sounds really hard. I'm right here with you.",
            "Let's sit for a minute. You don't have to do anything.",
          ],
          tweak: const <String>['Dim the overhead lights.'],
          dontSay: const <String>["Don't say 'it's not bedtime yet'."],
          generatedAt: DateTime.utc(2026, 5, 29, 19, 42),
        ),
        outcome: outcome,
        attempt: attempt,
        createdAt: createdAt ?? DateTime.utc(2026, 5, 29, 19, 42, 30),
        notes: notes,
        voiceNotePath: voiceNotePath,
        photoPath: photoPath,
      );

  Patient buildPatient() => Patient(
        id: 'demo-patient-mary',
        name: 'Mary Henderson',
        age: 78,
        diagnosis: "Alzheimer's disease, stage 5 (moderately severe)",
        diagnosedAt: DateTime.utc(2022, 4, 15),
        medications: const <CrisisMedication>[
          CrisisMedication(
              name: 'Donepezil', dose: '10 mg', schedule: 'every morning'),
        ],
        allergies: const <String>['Penicillin'],
        calms: const <String>['Sitting on her left side.'],
        escalates: const <String>['Strangers leaning over her.'],
        primaryCaregiver:
            const Contact(name: 'Sarah Henderson', phone: '(415) 555-0142'),
        healthcarePOA:
            const Contact(name: 'Sarah Henderson', phone: '(415) 555-0142'),
        advanceDirective: const AdvanceDirectiveStatus(
          onFileAt: 'Marin General Hospital',
          dnr: false,
        ),
      );

  // ---- DriftStorageProvider ------------------------------------------------

  group('DriftStorageProvider', () {
    late CareblazersDatabase db;
    late DriftStorageProvider storage;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      storage = DriftStorageProvider(db);
    });

    tearDown(() async {
      await storage.close();
    });

    test('round-trips a journal entry through insert + watch', () async {
      final JournalEntry entry = buildEntry(
        notes: 'Dimming the lights worked.',
        voiceNotePath: 'assets/seed/sample-voice-1.m4a',
      );
      await storage.insertJournalEntry(entry);

      final List<JournalEntry> rows =
          await storage.watchJournalEntries().first;
      expect(rows, hasLength(1));
      // Equality via freezed: same fields → equal instances.
      expect(rows.single, equals(entry));
    });

    test('newest entries come back first', () async {
      final DateTime base = DateTime.utc(2026, 5, 29, 12);
      final JournalEntry older = buildEntry(
        id: 'older',
        createdAt: base.subtract(const Duration(hours: 6)),
      );
      final JournalEntry newer = buildEntry(
        id: 'newer',
        createdAt: base,
      );
      await storage.insertJournalEntry(older);
      await storage.insertJournalEntry(newer);

      final List<JournalEntry> rows =
          await storage.watchJournalEntries().first;
      expect(rows.map((JournalEntry e) => e.id).toList(),
          <String>['newer', 'older']);
    });

    test('the window filter drops entries outside its range', () async {
      final DateTime now = DateTime.now();
      final JournalEntry recent = buildEntry(
        id: 'recent',
        createdAt: now.subtract(const Duration(hours: 1)),
      );
      final JournalEntry ancient = buildEntry(
        id: 'ancient',
        createdAt: now.subtract(const Duration(days: 120)),
      );
      await storage.insertJournalEntry(recent);
      await storage.insertJournalEntry(ancient);

      final List<JournalEntry> rows = await storage
          .watchJournalEntries(window: const Duration(days: 30))
          .first;
      expect(rows.map((JournalEntry e) => e.id).toList(),
          <String>['recent']);
    });

    test('updateJournalEntry persists outcome flips', () async {
      final JournalEntry entry = buildEntry(outcome: JournalOutcome.pending);
      await storage.insertJournalEntry(entry);

      final JournalEntry flipped =
          entry.copyWith(outcome: JournalOutcome.triedDifferent);
      await storage.updateJournalEntry(flipped);

      final List<JournalEntry> rows =
          await storage.watchJournalEntries().first;
      expect(rows.single.outcome, JournalOutcome.triedDifferent);
    });

    test('deleteJournalEntry removes the row', () async {
      await storage.insertJournalEntry(buildEntry(id: 'keep'));
      await storage.insertJournalEntry(buildEntry(id: 'drop'));

      await storage.deleteJournalEntry('drop');

      final List<JournalEntry> rows =
          await storage.watchJournalEntries().first;
      expect(rows.map((JournalEntry e) => e.id).toList(),
          <String>['keep']);
    });

    test(
      'listAllJournalEntries returns every entry newest-first, ignoring the '
      '30-day window (Issue #20 backup)',
      () async {
        final DateTime now = DateTime.now();
        // One entry well outside the on-screen 30-day window.
        final JournalEntry ancient = buildEntry(
          id: 'ancient',
          createdAt: now.subtract(const Duration(days: 400)),
        );
        final JournalEntry recent = buildEntry(
          id: 'recent',
          createdAt: now.subtract(const Duration(hours: 2)),
        );
        await storage.insertJournalEntry(ancient);
        await storage.insertJournalEntry(recent);

        // The windowed watch drops the ancient entry…
        final List<JournalEntry> windowed = await storage
            .watchJournalEntries(window: const Duration(days: 30))
            .first;
        expect(windowed.map((JournalEntry e) => e.id), <String>['recent']);

        // …but the backup read keeps it, newest first.
        final List<JournalEntry> all = await storage.listAllJournalEntries();
        expect(all.map((JournalEntry e) => e.id).toList(),
            <String>['recent', 'ancient']);
      },
    );

    test('upsertPatient + getPatient round-trip the loved one', () async {
      expect(await storage.getPatient(), isNull);

      final Patient mary = buildPatient();
      await storage.upsertPatient(mary);
      expect(await storage.getPatient(), equals(mary));

      // Upsert again with a name change — round-trips the new shape.
      final Patient renamed = mary.copyWith(name: 'Mary H.');
      await storage.upsertPatient(renamed);
      expect((await storage.getPatient())!.name, 'Mary H.');
    });

    test(
      'multi-patient: listPatients returns every loved one + setActive '
      'switches which getPatient resolves (Issue #6)',
      () async {
        // Empty before onboarding.
        expect(await storage.listPatients(), isEmpty);
        expect(await storage.getActivePatientId(), isNull);

        final Patient mary = buildPatient();
        final Patient frank = buildPatient().copyWith(
          id: 'demo-patient-frank',
          name: 'Frank Albright',
        );
        await storage.upsertPatient(mary);
        await storage.upsertPatient(frank);

        // listPatients returns both, name-sorted (Frank before Mary).
        final List<Patient> all = await storage.listPatients();
        expect(all.map((Patient p) => p.id).toList(),
            <String>['demo-patient-frank', 'demo-patient-mary']);

        // With no active id chosen, getPatient falls back to the first
        // row (single-patient v1 contract preserved) — name-sorted, so
        // Frank here.
        expect((await storage.getPatient())!.id, 'demo-patient-frank');

        // Switching the active id changes which patient getPatient
        // resolves, and it persists in getActivePatientId.
        await storage.setActivePatientId('demo-patient-mary');
        expect(await storage.getActivePatientId(), 'demo-patient-mary');
        expect((await storage.getPatient())!.id, 'demo-patient-mary');

        await storage.setActivePatientId('demo-patient-frank');
        expect((await storage.getPatient())!.id, 'demo-patient-frank');

        // A stale active id (no matching row) falls back to the first.
        await storage.setActivePatientId('does-not-exist');
        expect((await storage.getPatient())!.id, 'demo-patient-frank');
      },
    );

    test('single patient stays the default-active row (backward compat)',
        () async {
      // The v1 demo case: exactly one loved one, no active id ever set.
      await storage.upsertPatient(buildPatient());
      expect(await storage.getActivePatientId(), isNull);
      expect((await storage.getPatient())!.id, 'demo-patient-mary');
      expect(await storage.listPatients(), hasLength(1));
    });

    test('getSettings returns defaults when nothing is persisted',
        () async {
      final AppSettings loaded = await storage.getSettings();
      expect(loaded, equals(AppSettings.defaults()));
    });

    test('updateSettings persists the singleton row', () async {
      final AppSettings demo = AppSettings.defaults().copyWith(
        fontSize: FontSizeMultiplier.large,
        readScriptsAloud: false,
      );
      await storage.updateSettings(demo);

      final AppSettings loaded = await storage.getSettings();
      expect(loaded.fontSize, FontSizeMultiplier.large);
      expect(loaded.readScriptsAloud, isFalse);
    });

    test('reset() empties every table', () async {
      await storage.insertJournalEntry(buildEntry());
      await storage.upsertPatient(buildPatient());
      await storage.updateSettings(
        AppSettings.defaults().copyWith(fontSize: FontSizeMultiplier.xLarge),
      );

      await storage.reset();

      expect(await storage.watchJournalEntries().first, isEmpty);
      expect(await storage.getPatient(), isNull);
      // Settings goes back to defaults (the row was deleted).
      expect(await storage.getSettings(), equals(AppSettings.defaults()));
    });
  });

  // ---- InMemoryStorageProvider ---------------------------------------------

  group('InMemoryStorageProvider', () {
    late InMemoryStorageProvider storage;

    setUp(() {
      storage = InMemoryStorageProvider();
    });

    tearDown(() async {
      await storage.dispose();
    });

    test('honours the same StorageProvider interface', () {
      expect(storage, isA<StorageProvider>());
    });

    test('inserts + reads journal entries (newest first)', () async {
      final DateTime base = DateTime.utc(2026, 5, 29, 12);
      await storage.insertJournalEntry(buildEntry(
        id: 'a',
        createdAt: base.subtract(const Duration(hours: 2)),
      ));
      await storage.insertJournalEntry(buildEntry(id: 'b', createdAt: base));

      final List<JournalEntry> rows =
          await storage.watchJournalEntries().first;
      expect(rows.map((JournalEntry e) => e.id).toList(),
          <String>['b', 'a']);
    });

    test('updateJournalEntry is a no-op for unknown ids', () async {
      await storage.updateJournalEntry(buildEntry(id: 'never-inserted'));
      final List<JournalEntry> rows =
          await storage.watchJournalEntries().first;
      expect(rows, isEmpty);
    });

    test('deleteJournalEntry removes the row by id', () async {
      await storage.insertJournalEntry(buildEntry(id: 'a'));
      await storage.insertJournalEntry(buildEntry(id: 'b'));
      await storage.deleteJournalEntry('a');
      final List<JournalEntry> rows =
          await storage.watchJournalEntries().first;
      expect(rows.map((JournalEntry e) => e.id).toList(), <String>['b']);
    });

    test('watch re-emits when an entry is inserted', () async {
      final Stream<List<JournalEntry>> stream =
          storage.watchJournalEntries();
      final List<List<JournalEntry>> emissions =
          <List<JournalEntry>>[];
      final sub = stream.listen(emissions.add);

      // Initial emission.
      await Future<void>.delayed(Duration.zero);
      expect(emissions, hasLength(1));
      expect(emissions.first, isEmpty);

      await storage.insertJournalEntry(buildEntry(id: 'live'));
      await Future<void>.delayed(Duration.zero);
      expect(emissions, hasLength(2));
      expect(emissions.last.map((JournalEntry e) => e.id).toList(),
          <String>['live']);

      await sub.cancel();
    });

    test('listAllJournalEntries returns the full history newest-first',
        () async {
      final DateTime base = DateTime.utc(2026, 5, 29, 12);
      await storage.insertJournalEntry(buildEntry(
        id: 'old',
        createdAt: base.subtract(const Duration(days: 400)),
      ));
      await storage.insertJournalEntry(buildEntry(id: 'new', createdAt: base));

      final List<JournalEntry> all = await storage.listAllJournalEntries();
      expect(all.map((JournalEntry e) => e.id).toList(),
          <String>['new', 'old']);
    });

    test('patient + settings round-trips match Drift impl semantics',
        () async {
      expect(await storage.getPatient(), isNull);
      expect(await storage.getSettings(), equals(AppSettings.defaults()));

      final Patient mary = buildPatient();
      await storage.upsertPatient(mary);
      expect(await storage.getPatient(), equals(mary));

      final AppSettings tweaked = AppSettings.defaults()
          .copyWith(fontSize: FontSizeMultiplier.large);
      await storage.updateSettings(tweaked);
      expect((await storage.getSettings()).fontSize,
          FontSizeMultiplier.large);
    });

    test(
      'multi-patient list + active switching match Drift impl semantics '
      '(Issue #6)',
      () async {
        expect(await storage.listPatients(), isEmpty);
        expect(await storage.getActivePatientId(), isNull);

        final Patient mary = buildPatient();
        final Patient frank = buildPatient().copyWith(
          id: 'demo-patient-frank',
          name: 'Frank Albright',
        );
        await storage.upsertPatient(mary);
        await storage.upsertPatient(frank);

        // Name-sorted list.
        expect((await storage.listPatients()).map((Patient p) => p.id),
            <String>['demo-patient-frank', 'demo-patient-mary']);

        // Default-active = first (name-sorted) when none chosen.
        expect((await storage.getPatient())!.id, 'demo-patient-frank');

        await storage.setActivePatientId('demo-patient-mary');
        expect(await storage.getActivePatientId(), 'demo-patient-mary');
        expect((await storage.getPatient())!.id, 'demo-patient-mary');

        // reset() clears the active id back to null.
        await storage.reset();
        expect(await storage.getActivePatientId(), isNull);
        expect(await storage.listPatients(), isEmpty);
      },
    );

    test('reset() empties every collection', () async {
      await storage.insertJournalEntry(buildEntry());
      await storage.upsertPatient(buildPatient());
      await storage.updateSettings(
        AppSettings.defaults().copyWith(fontSize: FontSizeMultiplier.xLarge),
      );

      await storage.reset();

      expect(await storage.watchJournalEntries().first, isEmpty);
      expect(await storage.getPatient(), isNull);
      expect(await storage.getSettings(), equals(AppSettings.defaults()));
    });
  });

  // ---- Riverpod wiring -----------------------------------------------------

  group('storageProvider riverpod wiring', () {
    test('override hook swaps in a custom impl', () async {
      final InMemoryStorageProvider fake = InMemoryStorageProvider();
      addTearDown(fake.dispose);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(container.dispose);

      final StorageProvider impl = container.read(storageProvider);
      expect(identical(impl, fake), isTrue);

      await impl.insertJournalEntry(buildEntry());
      final List<JournalEntry> rows =
          await impl.watchJournalEntries().first;
      expect(rows, hasLength(1));
    });
  });
}

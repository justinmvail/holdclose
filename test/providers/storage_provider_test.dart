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

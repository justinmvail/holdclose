import 'package:careblazers/main.dart';
import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedClock() => DateTime.utc(2026, 5, 29, 19, 0);

JournalEntry _preexistingEntry() => JournalEntry(
      id: 'pre-existing-entry',
      behavior: Behavior.byId('upset')!,
      triage: const TriageAnswers(
        when: TriageWhen.morning,
        whatChanged: TriageWhatChanged.nothing,
        whatTried: TriageWhatTried.talked,
      ),
      result: DecoderResult(
        say: const <String>['carried-over line'],
        tweak: const <String>['carried-over tweak'],
        dontSay: const <String>['carried-over warning'],
        generatedAt: _fixedClock(),
      ),
      outcome: JournalOutcome.positive,
      attempt: 0,
      createdAt: _fixedClock(),
    );

Patient _preexistingPatient() => Patient(
      id: 'pre-existing-patient',
      name: 'Someone Else',
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

({ProviderContainer container, InMemoryStorageProvider storage}) _build({
  required bool resetOnLaunch,
}) {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  addTearDown(storage.dispose);
  // Pre-populate so the "state survives" assertions have something to
  // assert against — and so the "reset wiped it" assertions can verify
  // by absence after a reset run.
  storage.updateSettings(
    AppSettings.defaults().copyWith(resetOnLaunchDemo: resetOnLaunch),
  );
  storage.upsertPatient(_preexistingPatient());
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
}

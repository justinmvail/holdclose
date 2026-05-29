import 'dart:async';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/services/decoder_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const Behavior _sundowning =
    Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅');

const TriageAnswers _triage = TriageAnswers(
  when: TriageWhen.lateAfternoonEvening,
  whatChanged: TriageWhatChanged.nothing,
  whatTried: TriageWhatTried.talked,
);

DecoderResult _fixedResult() => DecoderResult(
      say: const <String>['line 1', 'line 2', 'line 3'],
      tweak: const <String>['dim the lights'],
      dontSay: const <String>["don't argue"],
      generatedAt: DateTime.utc(2026, 5, 29, 19, 42),
    );

DateTime _fixedClock() => DateTime.utc(2026, 5, 29, 19, 42);

DecoderService _service({
  required LLMProvider llm,
  required StorageProvider storage,
  String entryId = 'svc-entry-001',
}) {
  return DecoderService(
    llm: llm,
    storage: storage,
    entryIdFactory: () => entryId,
    clock: _fixedClock,
  );
}

/// Stream the canned [script] in order, with no inter-chunk delay so
/// tests don't pay the FakeLLMProvider's real-time 60ms pacing.
class _ScriptedLLM implements LLMProvider {
  _ScriptedLLM(this.script);

  final List<DecoderChunk> script;

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    for (final DecoderChunk chunk in script) {
      yield chunk;
    }
  }
}

void main() {
  group('DecoderService.decode', () {
    test('yields chunks from a FakeLLMProvider AND writes a JournalEntry',
        () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      // The default FakeLLMProvider streams in 8-token chunks with a
      // 60ms gap; shrink both so the test completes in milliseconds
      // without sacrificing the multi-chunk-then-done sequence.
      const FakeLLMProvider llm = FakeLLMProvider(
        chunkSize: 16,
        delay: Duration.zero,
        clock: _fixedClock,
      );
      final DecoderService svc = _service(llm: llm, storage: storage);

      final List<DecoderChunk> received = await svc
          .decode(behavior: _sundowning, triage: _triage, attempt: 0)
          .toList();

      // At least one partial precedes the terminal done — the FakeLLM
      // tokenizes its canned response into multiple chunks.
      expect(received.length, greaterThanOrEqualTo(2));
      expect(received.first, isA<DecoderChunkPartial>());
      expect(received.last, isA<DecoderChunkDone>());

      final List<JournalEntry> entries =
          await storage.watchJournalEntries().first;
      expect(entries, hasLength(1));
      expect(entries.single.behavior, _sundowning);
      expect(entries.single.attempt, 0);
      expect(entries.single.createdAt, _fixedClock());
    });

    test('on done, the entry has the parsed result attached', () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final DecoderResult expected = _fixedResult();
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        const DecoderChunk.partial(accumulatedJson: '{"say": ["lin'),
        DecoderChunk.done(result: expected),
      ]);
      final DecoderService svc = _service(llm: llm, storage: storage);

      await svc
          .decode(behavior: _sundowning, triage: _triage, attempt: 0)
          .toList();

      final JournalEntry stored =
          (await storage.watchJournalEntries().first).single;
      expect(stored.result, expected);
      // The pending placeholder result that was written on first
      // emission is overwritten by the parsed result on done.
      expect(stored.result.say, expected.say);
      expect(stored.outcome, JournalOutcome.pending);
    });

    test('on error chunk, the entry outcome is set to error', () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        const DecoderChunk.partial(accumulatedJson: '{"say":'),
        const DecoderChunk.error(message: 'shim offline'),
      ]);
      final DecoderService svc = _service(llm: llm, storage: storage);

      final List<DecoderChunk> received = await svc
          .decode(behavior: _sundowning, triage: _triage, attempt: 0)
          .toList();

      expect(received.last, isA<DecoderChunkError>());
      final JournalEntry stored =
          (await storage.watchJournalEntries().first).single;
      expect(stored.outcome, JournalOutcome.error);
      expect(stored.behavior, _sundowning);
    });

    test('error on the very first emission still writes an error entry',
        () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        const DecoderChunk.error(message: 'shim never came up'),
      ]);
      final DecoderService svc = _service(llm: llm, storage: storage);

      await svc
          .decode(behavior: _sundowning, triage: _triage, attempt: 0)
          .toList();

      final JournalEntry stored =
          (await storage.watchJournalEntries().first).single;
      expect(stored.outcome, JournalOutcome.error);
    });

    test('LLM stream that closes without a terminal chunk yields an error',
        () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        const DecoderChunk.partial(accumulatedJson: '{"say":'),
      ]);
      final DecoderService svc = _service(llm: llm, storage: storage);

      final List<DecoderChunk> received = await svc
          .decode(behavior: _sundowning, triage: _triage, attempt: 0)
          .toList();

      expect(received.last, isA<DecoderChunkError>());
      expect(
        (received.last as DecoderChunkError).message,
        contains('without a terminal chunk'),
      );

      final JournalEntry stored =
          (await storage.watchJournalEntries().first).single;
      expect(stored.outcome, JournalOutcome.error);
    });

    test('attempt is forwarded to the LLM call', () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final List<int> attemptsSeen = <int>[];
      final LLMProvider llm = _RecordingLLM(
        attemptsSeen,
        chunks: <DecoderChunk>[DecoderChunk.done(result: _fixedResult())],
      );
      // Each call mints a new id so the second `insert` doesn't
      // overwrite the first; the InMemoryStorageProvider keys by id.
      int counter = 0;
      final DecoderService svc = DecoderService(
        llm: llm,
        storage: storage,
        entryIdFactory: () => 'svc-${counter++}',
        clock: _fixedClock,
      );

      for (final int attempt in <int>[0, 1, 7]) {
        await svc
            .decode(behavior: _sundowning, triage: _triage, attempt: attempt)
            .toList();
      }

      expect(attemptsSeen, <int>[0, 1, 7]);
      final List<JournalEntry> entries =
          await storage.watchJournalEntries().first;
      expect(entries.map((JournalEntry e) => e.attempt).toSet(),
          <int>{0, 1, 7});
    });

    test('patient context falls back when storage has no patient', () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final _CapturingLLM llm = _CapturingLLM(
        chunks: <DecoderChunk>[DecoderChunk.done(result: _fixedResult())],
      );
      final DecoderService svc = _service(llm: llm, storage: storage);

      await svc
          .decode(behavior: _sundowning, triage: _triage, attempt: 0)
          .toList();

      expect(llm.lastPatient, isNotNull);
      expect(llm.lastPatient!.stage, 'unspecified');
      expect(llm.lastPatient!.age, 0);
    });

    test('patient context is built from the configured patient', () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      await storage.upsertPatient(
        Patient(
          id: 'demo-patient-mary',
          name: 'Mary Henderson',
          age: 78,
          diagnosis: "Alzheimer's, stage 5",
          diagnosedAt: DateTime.utc(2022, 4, 15),
          medications: const <Medication>[],
          allergies: const <String>['Penicillin'],
          calms: const <String>[],
          escalates: const <String>[],
          primaryCaregiver:
              const Contact(name: 'Sarah Henderson', phone: '(415) 555-0142'),
          healthcarePOA:
              const Contact(name: 'Sarah Henderson', phone: '(415) 555-0142'),
          advanceDirective: const AdvanceDirectiveStatus(
            onFileAt: 'Marin General',
            dnr: false,
          ),
        ),
      );
      final _CapturingLLM llm = _CapturingLLM(
        chunks: <DecoderChunk>[DecoderChunk.done(result: _fixedResult())],
      );
      final DecoderService svc = _service(llm: llm, storage: storage);

      await svc
          .decode(behavior: _sundowning, triage: _triage, attempt: 0)
          .toList();

      expect(llm.lastPatient!.stage, "Alzheimer's, stage 5");
      expect(llm.lastPatient!.age, 78);
    });
  });

  group('DecoderService.buildUserMessage', () {
    test('matches the §7.2 line format for a canonical behavior', () {
      const PatientContext patient =
          PatientContext(stage: 'stage 5', age: 78);
      final String message = DecoderService.buildUserMessage(
        behavior: _sundowning,
        triage: _triage,
        patient: patient,
        attempt: 2,
      );
      expect(message, contains('behavior: Sundowning'));
      expect(message, contains('when: late afternoon / evening'));
      expect(message, contains('what_changed: nothing'));
      expect(message, contains('what_tried: talked to them about it'));
      expect(message, contains('attempt: 2'));
      expect(message, contains('patient_context: stage 5, age 78'));
    });
  });

  group('decoderServiceProvider', () {
    test('singleton resolves to a DecoderService wired with the riverpod '
        'LLM + storage backends', () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        DecoderChunk.done(result: _fixedResult()),
      ]);
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          llmProvider.overrideWithValue(llm),
          storageBackendProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(c.dispose);

      final DecoderService svc = c.read(decoderServiceProvider);
      expect(svc.llm, same(llm));
      expect(svc.storage, same(storage));

      await svc
          .decode(behavior: _sundowning, triage: _triage, attempt: 0)
          .toList();

      final List<JournalEntry> entries =
          await storage.watchJournalEntries().first;
      expect(entries, hasLength(1));
    });
  });
}

class _RecordingLLM implements LLMProvider {
  _RecordingLLM(this.attemptsSeen, {required this.chunks});

  final List<int> attemptsSeen;
  final List<DecoderChunk> chunks;

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    attemptsSeen.add(attempt);
    for (final DecoderChunk chunk in chunks) {
      yield chunk;
    }
  }
}

class _CapturingLLM implements LLMProvider {
  _CapturingLLM({required this.chunks});

  final List<DecoderChunk> chunks;
  PatientContext? lastPatient;

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    lastPatient = patient;
    for (final DecoderChunk chunk in chunks) {
      yield chunk;
    }
  }
}

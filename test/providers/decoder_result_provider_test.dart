import 'dart:async';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/decoder_result_provider.dart';
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
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

  @override
  Stream<String> generateActivitySummary({
    int lastNHours = 24,
    required List<ActivityEvent> events,
  }) {
    throw UnimplementedError();
  }
}

ProviderContainer _container({
  required LLMProvider llm,
  required InMemoryStorageProvider storage,
  String entryId = 'fixed-entry-001',
}) {
  final ProviderContainer c = ProviderContainer(
    overrides: <Override>[
      llmProvider.overrideWithValue(llm),
      storageBackendProvider.overrideWithValue(storage),
      decoderResultClockProvider
          .overrideWithValue(() => DateTime.utc(2026, 5, 29, 19, 42)),
      decoderResultEntryIdFactoryProvider.overrideWithValue(() => entryId),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

const DecoderResultArgs _args = (
  behavior: _sundowning,
  triage: _triage,
  attempt: 0,
);

void main() {
  group('decoderResultProvider', () {
    /// Drive [provider] to its terminal state (done OR error) by
    /// listening, collecting every emission, and resolving the helper's
    /// future on the first done value or on a thrown error. The riverpod
    /// `.future` getter resolves on the FIRST data emission, so it
    /// can't be used here — partial chunks would short-circuit the wait.
    Future<DecoderProgress> drive(
      ProviderContainer c,
      DecoderResultArgs args,
    ) {
      final Completer<DecoderProgress> done = Completer<DecoderProgress>();
      final ProviderSubscription<AsyncValue<DecoderProgress>> sub =
          c.listen<AsyncValue<DecoderProgress>>(
        decoderResultProvider(args),
        (AsyncValue<DecoderProgress>? prev,
            AsyncValue<DecoderProgress> next) {
          if (done.isCompleted) return;
          if (next.hasError) {
            done.completeError(next.error!, next.stackTrace);
          } else if (next.hasValue && next.requireValue.done) {
            done.complete(next.requireValue);
          }
        },
        fireImmediately: true,
      );
      addTearDown(sub.close);
      return done.future;
    }

    test('streams partial → done with the parsed result', () async {
      final DecoderResult expected = _fixedResult();
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        const DecoderChunk.partial(accumulatedJson: '{"say": ["lin'),
        DecoderChunk.done(result: expected),
      ]);
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final ProviderContainer c = _container(llm: llm, storage: storage);

      final DecoderProgress last = await drive(c, _args);
      expect(last.done, isTrue);
      expect(last.partial, expected);
      expect(last.entry, isNotNull);
      expect(last.entry!.outcome, JournalOutcome.pending);
      expect(last.entry!.attempt, 0);
      expect(last.entry!.behavior, _sundowning);
    });

    test('writes a pending JournalEntry on first done', () async {
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        DecoderChunk.done(result: _fixedResult()),
      ]);
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final ProviderContainer c = _container(llm: llm, storage: storage);

      await drive(c, _args);

      final List<JournalEntry> entries =
          await storage.watchJournalEntries().first;
      expect(entries, hasLength(1));
      expect(entries.single.outcome, JournalOutcome.pending);
      expect(entries.single.behavior, _sundowning);
      expect(entries.single.attempt, 0);
      expect(entries.single.createdAt, DateTime.utc(2026, 5, 29, 19, 42));
    });

    test('error chunk surfaces as a DecoderResultException', () async {
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        const DecoderChunk.error(message: 'shim offline'),
      ]);
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final ProviderContainer c = _container(llm: llm, storage: storage);

      Object? thrown;
      try {
        await drive(c, _args);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<DecoderResultException>());
      expect((thrown! as DecoderResultException).message, 'shim offline');

      // No journal entry written when the stream errored before done.
      final List<JournalEntry> entries =
          await storage.watchJournalEntries().first;
      expect(entries, isEmpty);
    });

    test('attempt is forwarded to LLM call', () async {
      final List<int> attemptsSeen = <int>[];
      final LLMProvider llm = _RecordingLLM(
        attemptsSeen,
        chunks: <DecoderChunk>[
          DecoderChunk.done(result: _fixedResult()),
        ],
      );
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final ProviderContainer c = _container(llm: llm, storage: storage);

      for (final int attempt in <int>[0, 1, 7]) {
        await drive(c, (
          behavior: _sundowning,
          triage: _triage,
          attempt: attempt,
        ));
      }

      expect(attemptsSeen, <int>[0, 1, 7]);
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

  @override
  Stream<String> generateActivitySummary({
    int lastNHours = 24,
    required List<ActivityEvent> events,
  }) {
    throw UnimplementedError();
  }
}

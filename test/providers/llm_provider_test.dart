import 'dart:convert';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/seed/fake_llm_seeds.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

void main() {
  // Fixed triage so the call surface is identical across behaviors —
  // the fake doesn't branch on triage but the contract requires it.
  const TriageAnswers triage = TriageAnswers(
    when: TriageWhen.lateAfternoonEvening,
    whatChanged: TriageWhatChanged.nothing,
    whatTried: TriageWhatTried.talked,
  );
  const PatientContext patient = PatientContext(
    stage: 'stage 5 (moderately severe)',
    age: 78,
  );

  // Use a zero delay so the test suite stays fast — the streaming
  // semantics (chunk count + content) are independent of wall-clock
  // delay, and the production constructor defaults to 60ms.
  FakeLLMProvider buildFake() => FakeLLMProvider(
        delay: Duration.zero,
        clock: () => DateTime.utc(2026, 5, 29, 19, 42),
      );

  group('FakeLLMProvider — per-behavior stream contract', () {
    for (final Behavior b in Behavior.canonical) {
      test('${b.id} emits ≥3 partial chunks then a done', () async {
        final FakeLLMProvider fake = buildFake();
        final List<DecoderChunk> chunks = await fake
            .generateDecoderScript(
              behavior: b,
              triage: triage,
              patient: patient,
              attempt: 1,
            )
            .toList();

        // At least 3 partials + 1 done.
        expect(chunks.length, greaterThanOrEqualTo(4),
            reason: '${b.id} produced too few chunks: ${chunks.length}');

        final List<DecoderChunk> partials = chunks
            .whereType<DecoderChunkPartial>()
            .toList();
        expect(partials.length, greaterThanOrEqualTo(3),
            reason: '${b.id} produced only ${partials.length} partials');

        // Terminal chunk is a done carrying a non-empty DecoderResult.
        expect(chunks.last, isA<DecoderChunkDone>());
        final DecoderChunkDone done = chunks.last as DecoderChunkDone;
        final DecoderResult result = done.result;
        expect(result.say, isNotEmpty,
            reason: '${b.id} done.result.say was empty');
        expect(result.tweak, isNotEmpty,
            reason: '${b.id} done.result.tweak was empty');
        expect(result.dontSay, isNotEmpty,
            reason: '${b.id} done.result.dontSay was empty');
      });
    }
  });

  group('FakeLLMProvider — streaming shape', () {
    test('partials carry monotonically growing accumulated JSON', () async {
      final FakeLLMProvider fake = buildFake();
      final List<DecoderChunk> chunks = await fake
          .generateDecoderScript(
            behavior: Behavior.byId('sundowning')!,
            triage: triage,
            patient: patient,
            attempt: 1,
          )
          .toList();
      final List<String> accumulations = chunks
          .whereType<DecoderChunkPartial>()
          .map((DecoderChunkPartial p) => p.accumulatedJson)
          .toList();

      for (int i = 1; i < accumulations.length; i++) {
        expect(
          accumulations[i].startsWith(accumulations[i - 1]),
          isTrue,
          reason: 'partial #$i is not a prefix-superset of #${i - 1}',
        );
        expect(
          accumulations[i].length,
          greaterThan(accumulations[i - 1].length),
        );
      }
    });

    test(
      'final partial accumulation is parseable JSON and matches the done',
      () async {
        final FakeLLMProvider fake = buildFake();
        final List<DecoderChunk> chunks = await fake
            .generateDecoderScript(
              behavior: Behavior.byId('accusing')!,
              triage: triage,
              patient: patient,
              attempt: 1,
            )
            .toList();
        final List<DecoderChunkPartial> partials = chunks
            .whereType<DecoderChunkPartial>()
            .toList();
        final DecoderChunkDone done = chunks.last as DecoderChunkDone;

        final Map<String, dynamic> parsed =
            json.decode(partials.last.accumulatedJson)
                as Map<String, dynamic>;
        expect(parsed['say'], equals(done.result.say));
        expect(parsed['tweak'], equals(done.result.tweak));
        expect(parsed['dont_say'], equals(done.result.dontSay));
      },
    );

    test('clock stamps generatedAt on done.result', () async {
      final DateTime fixed = DateTime.utc(2026, 5, 29, 19, 42);
      final FakeLLMProvider fake = FakeLLMProvider(
        delay: Duration.zero,
        clock: () => fixed,
      );
      final List<DecoderChunk> chunks = await fake
          .generateDecoderScript(
            behavior: Behavior.byId('upset')!,
            triage: triage,
            patient: patient,
            attempt: 1,
          )
          .toList();
      final DecoderChunkDone done = chunks.last as DecoderChunkDone;
      expect(done.result.generatedAt, fixed);
    });

    test('free-text / unknown behavior id falls back gracefully',
        () async {
      final FakeLLMProvider fake = buildFake();
      const Behavior freeform = Behavior(
        id: 'freetext-something-else',
        label: 'Something else',
        glyph: '✍',
      );
      final List<DecoderChunk> chunks = await fake
          .generateDecoderScript(
            behavior: freeform,
            triage: triage,
            patient: patient,
            attempt: 1,
          )
          .toList();
      expect(chunks.last, isA<DecoderChunkDone>());
      final DecoderChunkDone done = chunks.last as DecoderChunkDone;
      expect(done.result.say, isNotEmpty);
      expect(done.result.tweak, isNotEmpty);
      expect(done.result.dontSay, isNotEmpty);
    });
  });

  group('fakeLLMSeeds — coverage of canonical behaviors', () {
    test('exposes a seed for every canonical behavior id', () {
      for (final Behavior b in Behavior.canonical) {
        expect(fakeLLMSeeds.containsKey(b.id), isTrue,
            reason: 'no fake seed for ${b.id}');
      }
    });

    test('every seed has 2–3 say + ≥1 tweak + ≥1 dont_say', () {
      for (final MapEntry<String, DecoderResult> e in fakeLLMSeeds.entries) {
        expect(e.value.say.length, inInclusiveRange(2, 3),
            reason: '${e.key} say count out of range');
        expect(e.value.tweak, isNotEmpty);
        expect(e.value.dontSay, isNotEmpty);
      }
    });

    test('no seed copy contains exclamation marks (BUILD_SPEC.md §3.3)',
        () {
      for (final MapEntry<String, DecoderResult> e in fakeLLMSeeds.entries) {
        final List<String> all = <String>[
          ...e.value.say,
          ...e.value.tweak,
          ...e.value.dontSay,
        ];
        for (final String s in all) {
          expect(s.contains('!'), isFalse,
              reason: '${e.key} contained an exclamation: $s');
        }
      }
    });
  });

  group('llmProvider riverpod wiring', () {
    test('defaults to FakeLLMProvider under test (USE_FAKE_LLM=true)',
        () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final LLMProvider impl = container.read(llmProvider);
      expect(impl, isA<FakeLLMProvider>());
    });

    test('override hook swaps in a custom impl', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          llmProvider.overrideWithValue(
            FakeLLMProvider(
              delay: Duration.zero,
              clock: () => DateTime.utc(2026, 1, 1),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final LLMProvider impl = container.read(llmProvider);
      final List<DecoderChunk> chunks = await impl
          .generateDecoderScript(
            behavior: Behavior.byId('wants_home')!,
            triage: triage,
            patient: patient,
            attempt: 1,
          )
          .toList();
      expect(chunks.last, isA<DecoderChunkDone>());
    });
  });
}

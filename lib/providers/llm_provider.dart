import 'dart:async';
import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/behavior.dart';
import '../models/decoder_result.dart';
import '../models/triage.dart';
import '../seed/fake_llm_seeds.dart';

part 'llm_provider.freezed.dart';
part 'llm_provider.g.dart';

/// One token in a decoder script stream (BUILD_SPEC.md §6.1 + §7.3).
///
/// The shim's SSE chunks accumulate text bytes; [DecoderChunk.partial]
/// carries the growing JSON string so the decoder result screen can
/// render the word-by-word fade-in. [DecoderChunk.done] is the terminal
/// success chunk — its [DecoderResult] is the parsed, validated whole.
/// [DecoderChunk.error] terminates the stream on parse failure or
/// transport error.
@freezed
sealed class DecoderChunk with _$DecoderChunk {
  const factory DecoderChunk.partial({
    required String accumulatedJson,
  }) = DecoderChunkPartial;

  const factory DecoderChunk.done({
    required DecoderResult result,
  }) = DecoderChunkDone;

  const factory DecoderChunk.error({
    required String message,
  }) = DecoderChunkError;
}

/// The slice of [Patient] the LLM call actually needs
/// (BUILD_SPEC.md §7.2).
///
/// Kept narrow on purpose: the system prompt forbids diagnosis claims
/// and prognosis statements, so we only pass the two facts the user
/// message template requires (stage + age). Everything else about the
/// patient lives in `models/patient.dart` and is used by the crisis
/// card, journal, etc. — not the LLM.
@freezed
abstract class PatientContext with _$PatientContext {
  const factory PatientContext({
    required String stage,
    required int age,
  }) = _PatientContext;
}

/// Backend for the decoder LLM call (BUILD_SPEC.md §6.1).
///
/// Two v1 implementations: [FakeLLMProvider] (canned + streamed for
/// tests and the demo tour) and [ClaudeCLIProvider] (HTTP shim,
/// stubbed here — Task 10 fills in the real impl). The app never
/// imports either concrete class directly; it goes through
/// [llmProvider] which picks based on `USE_FAKE_LLM`.
abstract class LLMProvider {
  /// Stream the decoder script for [behavior] + [triage]. Yields
  /// incremental [DecoderChunk]s as text arrives; terminates with
  /// either [DecoderChunk.done] or [DecoderChunk.error].
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  });
}

/// In-memory provider that streams hand-authored canned responses
/// from [fakeLLMSeeds] (BUILD_SPEC.md §6.1 + §10.2).
///
/// Streams the response JSON in [chunkSize]-token slices with [delay]
/// between each, then emits [DecoderChunk.done] with the parsed
/// [DecoderResult]. Used by `test/` widget tests and by the demo tour
/// — never live in real-user app runs.
class FakeLLMProvider implements LLMProvider {
  const FakeLLMProvider({
    this.chunkSize = 8,
    this.delay = const Duration(milliseconds: 60),
    this.clock = _defaultClock,
  });

  /// Tokens per partial chunk (BUILD_SPEC.md §6.1 — fake streams in
  /// 8-token chunks).
  final int chunkSize;

  /// Inter-chunk delay (BUILD_SPEC.md §6.1 — 60ms between chunks).
  final Duration delay;

  /// Injectable clock so tests can pin `generatedAt` deterministically.
  final DateTime Function() clock;

  static DateTime _defaultClock() => DateTime.now();

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    final DecoderResult canned =
        fakeLLMSeeds[behavior.id] ?? _freeTextFallback();
    final DecoderResult stamped = canned.copyWith(generatedAt: clock());

    // Serialize without `generated_at` — the LLM doesn't emit that
    // field in real output (it's set client-side at parse-done), so
    // the streamed JSON the fake produces matches the shape of real
    // shim responses.
    final Map<String, dynamic> jsonShape = stamped.toJson()
      ..remove('generatedAt')
      ..remove('generated_at');
    final String fullJson =
        const JsonEncoder.withIndent('  ').convert(jsonShape);

    final List<String> tokens = _tokenize(fullJson);
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < tokens.length; i += chunkSize) {
      final int end = (i + chunkSize) > tokens.length
          ? tokens.length
          : (i + chunkSize);
      for (int j = i; j < end; j++) {
        buffer.write(tokens[j]);
      }
      yield DecoderChunk.partial(accumulatedJson: buffer.toString());
      if (end < tokens.length) {
        await Future<void>.delayed(delay);
      }
    }
    yield DecoderChunk.done(result: stamped);
  }

  /// Tokenize on whitespace boundaries, keeping both the whitespace and
  /// non-whitespace runs so the accumulated buffer reconstructs the
  /// original string exactly.
  static List<String> _tokenize(String text) {
    final RegExp re = RegExp(r'\s+|\S+');
    return re.allMatches(text).map((Match m) => m.group(0)!).toList();
  }

  /// Soft, generic Natali-voice script for the free-text "Something
  /// else — describe it" path (BUILD_SPEC.md §5.2). Keeps the demo
  /// alive when the picker routes a behavior id outside the canonical
  /// 8 without falling back to a crash.
  DecoderResult _freeTextFallback() {
    return DecoderResult(
      say: const <String>[
        "I'm right here with you. You're not alone in this moment.",
        "Let's take a slow breath together — there's no rush.",
        'Tell me what would feel a little better right now.',
      ],
      tweak: const <String>[
        'Lower your voice and slow your pace. Sit beside them at eye level — small physical alignments calm the room.',
      ],
      dontSay: const <String>[
        "Don't try to argue the facts or explain the situation. Comfort first; logic almost never lands in the moment.",
      ],
      generatedAt: clock(),
    );
  }
}

/// Stub for the real shim-backed provider (BUILD_SPEC.md §6.1). Task 10
/// replaces this body with HTTP-shim wiring; for now it emits a single
/// [DecoderChunk.error] so any accidental real-mode runs surface a
/// clear message instead of hanging.
class ClaudeCLIProvider implements LLMProvider {
  const ClaudeCLIProvider();

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    yield const DecoderChunk.error(
      message:
          'ClaudeCLIProvider not yet wired — run with '
          '--dart-define=USE_FAKE_LLM=true until Task 10 lands.',
    );
  }
}

/// Build-time flag (BUILD_SPEC.md §1 — `USE_FAKE_LLM`).
///
/// Defaults to true so `flutter test` and `flutter run` without any
/// dart-define both pick up the canned fake. Flip to false (real shim
/// mode) with `flutter run --dart-define=USE_FAKE_LLM=false`.
const bool _useFakeLLM = bool.fromEnvironment(
  'USE_FAKE_LLM',
  defaultValue: true,
);

/// Riverpod-wired backend selection. Widgets and services read
/// `ref.watch(llmProvider)` and get whichever impl the build mode
/// picked — they never see the concrete class.
@Riverpod(keepAlive: true)
LLMProvider llm(Ref ref) =>
    _useFakeLLM ? const FakeLLMProvider() : const ClaudeCLIProvider();

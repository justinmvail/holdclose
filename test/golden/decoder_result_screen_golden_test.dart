import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/decoder_result_provider.dart';
import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:careblazers/screens/decoder/decoder_result_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// LLM stand-in that emits one canned DONE chunk so the golden captures
/// the post-stream, full-layout state (header → say → tweak → don't say
/// → footer → outcome buttons) rather than the in-flight skeleton.
class _DoneLLM implements LLMProvider {
  _DoneLLM(this.result);

  final DecoderResult result;

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    yield DecoderChunk.done(result: result);
  }

  @override
  Stream<String> generateActivitySummary({
    int lastNHours = 24,
    required List<ActivityEvent> events,
  }) {
    throw UnimplementedError();
  }
}

DecoderResult _seedResult() => DecoderResult(
      say: const <String>[
        "That sounds really hard. I'm right here with you.",
        "Let's sit together for a minute.",
        "I'm going to put on the song you like.",
      ],
      tweak: const <String>[
        'Dim overhead lights and switch on a single warm lamp.',
      ],
      dontSay: const <String>[
        "Don't say 'you already asked me that'.",
      ],
      generatedAt: DateTime.utc(2026, 5, 29, 19, 42),
    );

void main() {
  group('DecoderResultScreen golden', () {
    goldenTest(
      'renders the done-state layout with all three outcome buttons',
      fileName: 'decoder_result_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'done (full §5.4 layout)',
            child: ProviderScope(
              overrides: <Override>[
                llmProvider.overrideWithValue(_DoneLLM(_seedResult())),
                storageBackendProvider
                    .overrideWithValue(InMemoryStorageProvider()),
                ttsProvider
                    .overrideWith((Ref _) => const NoopTTSProvider()),
                linkLauncherProvider
                    .overrideWithValue(RecordingLinkLauncher()),
                decoderResultClockProvider.overrideWithValue(
                  () => DateTime.utc(2026, 5, 29, 19, 42),
                ),
                decoderResultEntryIdFactoryProvider
                    .overrideWithValue(() => 'golden-entry-0001'),
                ttsSettingsProvider.overrideWithValue(
                  AppSettings.defaults(),
                ),
              ],
              child: SizedBox(
                width: 420,
                height: 1100,
                child: MaterialApp.router(
                  routerConfig: _goldenRouter(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

GoRouter _goldenRouter() {
  return GoRouter(
    initialLocation: '/decoder/result',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
      GoRoute(
        path: '/decoder/result',
        builder: (BuildContext context, GoRouterState state) =>
            const DecoderResultScreen(
          behavior: Behavior(
            id: 'sundowning',
            label: 'Sundowning',
            glyph: '🌅',
          ),
          triage: TriageAnswers(
            when: TriageWhen.lateAfternoonEvening,
            whatChanged: TriageWhatChanged.nothing,
            whatTried: TriageWhatTried.talked,
          ),
        ),
      ),
    ],
  );
}

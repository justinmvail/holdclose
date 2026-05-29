import 'dart:async';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/decoder_result_provider.dart';
import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:careblazers/screens/decoder/decoder_result_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../_semantics_matchers.dart';

/// Spying TTS provider so tests can assert what the AppBar 🔊 and the
/// per-line ▶ buttons actually handed off without spinning up a
/// flutter_tts platform channel.
class _SpyTts implements TTSProvider {
  final List<String> spoken = <String>[];

  @override
  Future<void> speak(
    String text, {
    required String voiceId,
    required double speed,
  }) async {
    spoken.add(text);
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<List<TTSVoice>> availableVoices() async => const <TTSVoice>[];
}

/// LLM stand-in that emits a fixed list of chunks. Counts invocations
/// and snapshots the `attempt` argument so tests can verify the "Try
/// a different approach" button bumps attempt + 1.
class _ScriptedLLM implements LLMProvider {
  _ScriptedLLM(this.script);

  final List<DecoderChunk> script;
  final List<int> attemptsSeen = <int>[];

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    attemptsSeen.add(attempt);
    for (final DecoderChunk chunk in script) {
      yield chunk;
    }
  }
}

const Behavior _sundowning =
    Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅');

const TriageAnswers _triage = TriageAnswers(
  when: TriageWhen.lateAfternoonEvening,
  whatChanged: TriageWhatChanged.nothing,
  whatTried: TriageWhatTried.talked,
);

DecoderResult _stamped() => DecoderResult(
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

Future<({
  GoRouter router,
  InMemoryStorageProvider storage,
  _SpyTts tts,
  RecordingLinkLauncher launcher,
  LLMProvider llm,
  List<String> mintedIds,
})> _pumpScreen(
  WidgetTester tester, {
  required LLMProvider llm,
  int initialAttempt = 0,
  String idPrefix = 'entry',
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  addTearDown(storage.dispose);
  final _SpyTts tts = _SpyTts();
  final RecordingLinkLauncher launcher = RecordingLinkLauncher();
  final List<String> mintedIds = <String>[];
  int counter = 0;

  final GoRouter router = GoRouter(
    initialLocation: '/decoder/result',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('home-after-helped'))),
      ),
      GoRoute(
        path: '/decoder/result',
        builder: (BuildContext context, GoRouterState state) =>
            DecoderResultScreen(
          behavior: _sundowning,
          triage: _triage,
          initialAttempt: initialAttempt,
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        llmProvider.overrideWithValue(llm),
        storageBackendProvider.overrideWithValue(storage),
        ttsBackendOverride(tts),
        linkLauncherProvider.overrideWithValue(launcher),
        decoderResultClockProvider
            .overrideWithValue(() => DateTime.utc(2026, 5, 29, 19, 42)),
        decoderResultEntryIdFactoryProvider.overrideWithValue(() {
          counter += 1;
          final String id = '$idPrefix-$counter';
          mintedIds.add(id);
          return id;
        }),
        ttsSettingsProvider.overrideWithValue(AppSettings.defaults()),
      ],
      // MaterialApp.builder wraps the navigator subtree — the inner
      // MediaQuery override has to land HERE, not above MaterialApp,
      // because MaterialApp re-creates its own MediaQuery from the
      // FlutterView window and would otherwise shadow ours. Forcing
      // disableAnimations: true keeps the skeleton's repeating
      // AnimationController out of the pump-and-settle wait loop —
      // its build path renders a static frame when reduce-motion is
      // on (BUILD_SPEC.md §11.6).
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            accessibleNavigation: true,
            disableAnimations: true,
          ),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
  return (
    router: router,
    storage: storage,
    tts: tts,
    launcher: launcher,
    llm: llm,
    mintedIds: mintedIds,
  );
}

/// Tts provider override that pins the [TTSProvider] without going
/// through the quiet-hours / settings selector logic.
Override ttsBackendOverride(TTSProvider impl) =>
    ttsProvider.overrideWith((Ref ref) => impl);

void main() {
  group('DecoderResultScreen — streaming (BUILD_SPEC.md §5.4)', () {
    testWidgets('shows skeleton + accumulated text before done',
        (WidgetTester tester) async {
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        const DecoderChunk.partial(accumulatedJson: '{"say": ["that '),
        const DecoderChunk.partial(
            accumulatedJson: '{"say": ["that sounds hard"'),
      ]);
      await _pumpScreen(tester, llm: llm);

      // Initial frame: loading state — header + skeleton.
      await tester.pump();
      expect(find.text('Dr. Natali says:'), findsOneWidget);
      expect(find.byKey(DecoderResultScreen.skeletonKey), findsOneWidget);

      // First partial arrives.
      await tester.pump();
      expect(find.byKey(DecoderResultScreen.skeletonKey), findsOneWidget);
      // Either the structured partial render landed (sayLineKey(0)) or
      // the raw streaming text fallback did — the spec says "word-by-
      // word fade-in of partial content", which both shapes satisfy.
      final bool gotStructured =
          find.byKey(DecoderResultScreen.sayLineKey(0)).evaluate().isNotEmpty;
      final bool gotStreamingFallback = find
          .byKey(DecoderResultScreen.streamingTextKey)
          .evaluate()
          .isNotEmpty;
      expect(gotStructured || gotStreamingFallback, isTrue,
          reason: 'streaming should surface SOME partial content');
    });

    testWidgets('on done renders the full §5.4 layout',
        (WidgetTester tester) async {
      final DecoderResult result = _stamped();
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        const DecoderChunk.partial(accumulatedJson: '{"say":['),
        DecoderChunk.done(result: result),
      ]);
      await _pumpScreen(tester, llm: llm);
      await tester.pumpAndSettle();

      // Sectional headers, in §5.4 order.
      expect(find.text('Dr. Natali says:'), findsOneWidget);
      expect(find.text('Try saying:'), findsOneWidget);
      expect(find.text('Try this in the room:'), findsOneWidget);
      expect(find.text("Don't say:"), findsOneWidget);

      // Say lines render with per-line ▶ play buttons.
      for (int i = 0; i < result.say.length; i++) {
        expect(find.byKey(DecoderResultScreen.sayLineKey(i)), findsOneWidget);
        expect(
          find.byKey(DecoderResultScreen.sayLinePlayKey(i)),
          findsOneWidget,
        );
      }

      // Tweak + don't say lines render.
      for (int i = 0; i < result.tweak.length; i++) {
        expect(find.byKey(DecoderResultScreen.tweakLineKey(i)), findsOneWidget);
      }
      for (int i = 0; i < result.dontSay.length; i++) {
        expect(
          find.byKey(DecoderResultScreen.dontSayLineKey(i)),
          findsOneWidget,
        );
      }

      // Footer disclaimer is present (BUILD_SPEC.md §13.1).
      expect(find.byKey(DecoderResultScreen.footerKey), findsOneWidget);
      expect(
        find.textContaining('not a substitute for medical advice'),
        findsOneWidget,
      );

      // All three outcome buttons present.
      expect(find.byKey(DecoderResultScreen.thatHelpedKey), findsOneWidget);
      expect(
        find.byKey(DecoderResultScreen.differentApproachKey),
        findsOneWidget,
      );
      expect(find.byKey(DecoderResultScreen.talkToNataliKey), findsOneWidget);
    });

    testWidgets('auto-logs a JournalEntry on first done',
        (WidgetTester tester) async {
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        DecoderChunk.done(result: _stamped()),
      ]);
      final pumped = await _pumpScreen(tester, llm: llm);
      await tester.pumpAndSettle();

      // runAsync() so the storage stream's microtask round-trip happens
      // on the real clock — TestWidgetsFlutterBinding's fake clock
      // doesn't drain the change-controller's onListen synchronously,
      // and `.first` would otherwise hang forever waiting on a
      // microtask the binding parks.
      final List<JournalEntry> entries = await tester.runAsync(() =>
              pumped.storage.watchJournalEntries().first) ??
          <JournalEntry>[];
      expect(entries, hasLength(1));
      final JournalEntry entry = entries.single;
      expect(entry.behavior, _sundowning);
      expect(entry.triage, _triage);
      expect(entry.outcome, JournalOutcome.pending);
      expect(entry.attempt, 0);
      expect(entry.createdAt, DateTime.utc(2026, 5, 29, 19, 42));
      expect(pumped.mintedIds, hasLength(1));
    });
  });

  group('DecoderResultScreen — outcome buttons', () {
    testWidgets('"That helped" updates the entry + navigates home',
        (WidgetTester tester) async {
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        DecoderChunk.done(result: _stamped()),
      ]);
      final pumped = await _pumpScreen(tester, llm: llm);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(DecoderResultScreen.thatHelpedKey));
      await tester.pumpAndSettle();

      // Routed home.
      expect(pumped.router.routerDelegate.currentConfiguration.uri.path,
          '/');
      expect(find.text('home-after-helped'), findsOneWidget);

      // Entry mutated to positive.
      final List<JournalEntry> entries = await tester.runAsync(() =>
              pumped.storage.watchJournalEntries().first) ??
          <JournalEntry>[];
      expect(entries, hasLength(1));
      expect(entries.single.outcome, JournalOutcome.positive);
      // createdAt must be preserved across the outcome update — the
      // journal "today / yesterday" grouping depends on it.
      expect(entries.single.createdAt, DateTime.utc(2026, 5, 29, 19, 42));
    });

    testWidgets(
      '"Try a different approach" re-invokes LLM with attempt + 1',
      (WidgetTester tester) async {
        final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
          DecoderChunk.done(result: _stamped()),
        ]);
        await _pumpScreen(tester, llm: llm);
        await tester.pumpAndSettle();

        expect(llm.attemptsSeen, <int>[0]);

        await tester
            .tap(find.byKey(DecoderResultScreen.differentApproachKey));
        await tester.pumpAndSettle();

        expect(llm.attemptsSeen, <int>[0, 1],
            reason:
                'Tapping "Different approach" must re-invoke the LLM with attempt + 1');
      },
    );

    testWidgets('"Talk to Natali" launches the careblazers.com URL',
        (WidgetTester tester) async {
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        DecoderChunk.done(result: _stamped()),
      ]);
      final pumped = await _pumpScreen(tester, llm: llm);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(DecoderResultScreen.talkToNataliKey));
      await tester.pumpAndSettle();

      expect(pumped.launcher.launched, hasLength(1));
      final Uri uri = pumped.launcher.launched.single;
      expect(uri.host, 'careblazers.com');
      expect(uri.path, '/care-collective');
      expect(uri.queryParameters['utm_source'], 'app');
      expect(uri.queryParameters['utm_medium'], 'decoder');
    });
  });

  group('DecoderResultScreen — TTS', () {
    testWidgets('AppBar PLAY reads every say + tweak line via TTS',
        (WidgetTester tester) async {
      final DecoderResult result = _stamped();
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        DecoderChunk.done(result: result),
      ]);
      final pumped = await _pumpScreen(tester, llm: llm);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(DecoderResultScreen.playAllKey));
      await tester.pumpAndSettle();

      // Every say line + every tweak got spoken (in order). Don't-say
      // is a warning, not a script — it intentionally isn't read.
      expect(pumped.tts.spoken, <String>[...result.say, ...result.tweak]);
    });

    testWidgets('per-line ▶ reads just that line via TTS',
        (WidgetTester tester) async {
      final DecoderResult result = _stamped();
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        DecoderChunk.done(result: result),
      ]);
      final pumped = await _pumpScreen(tester, llm: llm);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(DecoderResultScreen.sayLinePlayKey(1)));
      await tester.pumpAndSettle();

      expect(pumped.tts.spoken, <String>[result.say[1]]);
    });
  });

  group('DecoderResultScreen — error state', () {
    testWidgets('shows retry + hides outcome buttons on error chunk',
        (WidgetTester tester) async {
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        const DecoderChunk.error(message: 'shim offline'),
      ]);
      await _pumpScreen(tester, llm: llm);
      // The provider awaits storage.getPatient() then `await for`s a
      // single error chunk before throwing — that's a couple of
      // microtask hops the fake clock doesn't drain inside one pump.
      // runAsync() escapes the fake clock so the async hops complete
      // before we pump the resulting AsyncError frame.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      // Pump a few more frames just in case.
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.byKey(DecoderResultScreen.retryKey), findsOneWidget);
      expect(find.textContaining('shim offline'), findsOneWidget);
      expect(find.byKey(DecoderResultScreen.thatHelpedKey), findsNothing);
      expect(
        find.byKey(DecoderResultScreen.differentApproachKey),
        findsNothing,
      );
      expect(find.byKey(DecoderResultScreen.talkToNataliKey), findsNothing);
    });

    testWidgets('retry button re-invokes LLM',
        (WidgetTester tester) async {
      // First call errors; second call returns a clean done. The
      // retry button invalidates the family, so the screen's next
      // build re-subscribes and the scripted LLM advances by one call.
      int callCount = 0;
      final FakeRetryLlm llm = FakeRetryLlm(onCall: () {
        callCount += 1;
        if (callCount == 1) {
          return <DecoderChunk>[
            const DecoderChunk.error(message: 'shim offline'),
          ];
        }
        return <DecoderChunk>[
          DecoderChunk.done(result: _stamped()),
        ];
      });

      await _pumpScreen(tester, llm: llm);
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();

      expect(find.byKey(DecoderResultScreen.retryKey), findsOneWidget);
      await tester.tap(find.byKey(DecoderResultScreen.retryKey));
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();

      expect(find.byKey(DecoderResultScreen.retryKey), findsNothing);
      expect(find.text('Try saying:'), findsOneWidget);
      expect(callCount, 2);
    });
  });

  group('DecoderResultScreen — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets('every interactive widget announces an explicit label',
        (WidgetTester tester) async {
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        DecoderChunk.done(result: _stamped()),
      ]);
      await _pumpScreen(tester, llm: llm);
      await tester.pumpAndSettle();

      expect(
        hasSemanticsLabel(tester, RegExp('Read the full script aloud')),
        isTrue,
      );
      expect(
        hasSemanticsLabel(tester, RegExp('Play this script line aloud')),
        isTrue,
      );
      expect(
        hasSemanticsLabel(tester, RegExp('That helped')),
        isTrue,
      );
      expect(
        hasSemanticsLabel(tester, RegExp('Try a different approach')),
        isTrue,
      );
      expect(
        hasSemanticsLabel(tester, RegExp('Talk to Natali')),
        isTrue,
      );
    });
  });

  group('DecoderResultScreen — VoiceOver section order (§5.4)', () {
    testWidgets('semantic sort keys put header → say → tweak → dont-say → footer',
        (WidgetTester tester) async {
      final _ScriptedLLM llm = _ScriptedLLM(<DecoderChunk>[
        DecoderChunk.done(result: _stamped()),
      ]);
      await _pumpScreen(tester, llm: llm);
      await tester.pumpAndSettle();

      // The five §5.4 sections each have an OrdinalSortKey set in build
      // order — pull them off the Semantics widgets that live INSIDE
      // the DecoderResultScreen subtree (the AppBar's framework-
      // injected semantics also carry an OrdinalSortKey we don't own).
      // Monotonic ordinal values confirm the reading order VoiceOver /
      // TalkBack will use without needing a full a11y walk.
      final Iterable<Semantics> annotated = tester
          .widgetList<Semantics>(
            find.descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Semantics),
            ),
          )
          .where((Semantics s) =>
              s.properties.sortKey is OrdinalSortKey);
      final List<double> ordinals = <double>[
        for (final Semantics s in annotated)
          (s.properties.sortKey! as OrdinalSortKey).order,
      ];
      expect(ordinals, <double>[0, 1, 2, 3, 4]);
    });
  });
}

/// LLM stand-in that delegates to a per-call closure so the retry test
/// can return an error chunk first, then a clean done on the second
/// subscription.
class FakeRetryLlm implements LLMProvider {
  FakeRetryLlm({required this.onCall});

  final List<DecoderChunk> Function() onCall;

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    for (final DecoderChunk chunk in onCall()) {
      yield chunk;
    }
  }
}

import 'dart:async';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/triage_provider.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/decoder/decoder_result_screen.dart';
import 'package:careblazers/screens/decoder/triage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../_semantics_matchers.dart';

const Behavior _sundowning =
    Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅');

/// Pump a triage screen at `/decoder/triage` with [args] in the route
/// extras, plus a `/decoder/result` stub that captures the pushed
/// extras so the Q3 → Next navigation assertion can introspect what
/// the screen actually handed forward.
Future<({
  ProviderContainer container,
  List<Object?> capturedResultExtras,
  GoRouter router,
})> _pumpTriage(
  WidgetTester tester, {
  TriageArgs args = const TriageArgs.forBehavior(_sundowning),
}) async {
  // Wide enough that the PathHeader's full breadcrumb trail
  // (Home › Medical › Journal › What's happening? › Triage) lays out
  // without a horizontal RenderFlex overflow. The old AppBar header fit
  // at 400px wide; the breadcrumb header needs more room.
  await tester.binding.setSurfaceSize(const Size(600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<Object?> capturedResultExtras = <Object?>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();

  // Routes:
  //   '/' — a stub "home" so the BackButton on Q1 has somewhere to
  //   pop to (otherwise maybePop is a no-op and Back-from-Q1 looks
  //   indistinguishable from a stuck state).
  //   '/decoder/behavior' — a stub for the picker that the triage
  //   PathHeader's parent crumb ("What's happening?") `context.go`s to.
  //   It's the back affordance now that the standalone "Back to X"
  //   control was removed from PathHeader.
  //   '/decoder/triage' — the real screen.
  //   '/decoder/result' — a stub that captures `state.extra`.
  final GoRouter router = GoRouter(
    initialLocation: '/',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('test-home'))),
      ),
      GoRoute(
        path: '/decoder/behavior',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('test-behavior-picker'))),
      ),
      GoRoute(
        path: '/decoder/triage',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            TriageScreen(args: args),
      ),
      GoRoute(
        path: '/decoder/result',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) {
          capturedResultExtras.add(state.extra);
          return const Scaffold(body: Center(child: Text('test-result')));
        },
      ),
    ],
  );

  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  // Push triage onto the root navigator so the AppBar's back arrow
  // renders the same way it does when reached from the picker.
  unawaited(router.push('/decoder/triage'));
  await tester.pumpAndSettle();

  return (
    container: container,
    capturedResultExtras: capturedResultExtras,
    router: router,
  );
}

void main() {
  group('TriageScreen — BUILD_SPEC.md §5.3 chrome', () {
    testWidgets('renders Q1 prompt, "1 of 3" progress, and behavior chip',
        (WidgetTester tester) async {
      await _pumpTriage(tester);

      expect(find.byType(TriageScreen), findsOneWidget);
      expect(
        find.byKey(TriageScreen.questionKey(0)),
        findsOneWidget,
        reason: 'Q1 prompt should render on entry',
      );
      expect(find.text('When does it tend to happen?'), findsOneWidget);

      expect(find.byKey(TriageScreen.progressKey), findsOneWidget);
      expect(find.text('1 of 3'), findsOneWidget);

      expect(find.byKey(TriageScreen.behaviorChipKey), findsOneWidget);
      expect(find.text('Sundowning'), findsOneWidget);
    });

    testWidgets('renders all 5 Q1 options in spec order',
        (WidgetTester tester) async {
      await _pumpTriage(tester);

      const List<String> expectedLabels = <String>[
        'Morning',
        'Afternoon',
        'Late afternoon / evening',
        'Night',
        "Just started — don't know yet",
      ];
      for (int i = 0; i < expectedLabels.length; i++) {
        expect(
          find.byKey(TriageScreen.optionKey(0, i)),
          findsOneWidget,
          reason: 'Q1 option $i missing',
        );
        expect(
          find.text(expectedLabels[i]),
          findsOneWidget,
          reason: '"${expectedLabels[i]}" label missing on Q1',
        );
      }
    });

    testWidgets('renders BackButton + Next button',
        (WidgetTester tester) async {
      await _pumpTriage(tester);

      expect(find.byKey(TriageScreen.backButtonKey), findsOneWidget);
      expect(find.byKey(TriageScreen.nextButtonKey), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Next →'), findsOneWidget);
    });

    testWidgets('free-text args render a "Something else" chip',
        (WidgetTester tester) async {
      await _pumpTriage(tester, args: const TriageArgs.freeText());

      expect(find.byKey(TriageScreen.behaviorChipKey), findsOneWidget);
      expect(find.text('Something else'), findsOneWidget);
    });
  });

  group('TriageScreen — Next button enable/disable', () {
    testWidgets('Next is disabled on entry with no selection made',
        (WidgetTester tester) async {
      await _pumpTriage(tester);

      final ElevatedButton next = tester.widget<ElevatedButton>(
        find.byKey(TriageScreen.nextButtonKey),
      );
      expect(
        next.onPressed,
        isNull,
        reason: 'Next must be disabled until the caregiver picks an answer',
      );
    });

    testWidgets('Next enables once a Q1 option is tapped',
        (WidgetTester tester) async {
      final pumped = await _pumpTriage(tester);

      await tester.tap(find.byKey(TriageScreen.optionKey(0, 0)));
      await tester.pumpAndSettle();

      final ElevatedButton next = tester.widget<ElevatedButton>(
        find.byKey(TriageScreen.nextButtonKey),
      );
      expect(next.onPressed, isNotNull);
      expect(
        pumped.container.read(triageProvider).when,
        TriageWhen.morning,
        reason: 'tapping Q1 option 0 should set TriageWhen.morning',
      );
    });
  });

  group('TriageScreen — sequential question progression', () {
    testWidgets('Next from Q1 advances to Q2; Next from Q2 advances to Q3',
        (WidgetTester tester) async {
      await _pumpTriage(tester);

      // Q1 → Q2
      await tester.tap(find.byKey(TriageScreen.optionKey(0, 0)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(TriageScreen.questionKey(1)), findsOneWidget);
      expect(find.text('What changed recently?'), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);
      // Next disables again because Q2 has no selection yet.
      final ElevatedButton nextAtQ2 = tester.widget<ElevatedButton>(
        find.byKey(TriageScreen.nextButtonKey),
      );
      expect(nextAtQ2.onPressed, isNull);

      // Q2 → Q3
      await tester.tap(find.byKey(TriageScreen.optionKey(1, 1)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(TriageScreen.questionKey(2)), findsOneWidget);
      expect(find.text('What have you already tried?'), findsOneWidget);
      expect(find.text('3 of 3'), findsOneWidget);
    });
  });

  group('TriageScreen — breadcrumb back affordance leaves the flow', () {
    // The standalone "‹ Back to X" control was removed from PathHeader;
    // the parent breadcrumb crumb is the only back affordance now, and
    // tapping it runs `context.go(crumb.route)`. For triage the parent
    // crumb ("What's happening?") routes to `/decoder/behavior`, so a
    // crumb tap is a route-level navigation OUT of the triage flow — no
    // longer the old in-page setState that stepped the question index
    // down while keeping the picked answer painted. These tests now
    // verify that the crumb back affordance navigates to its parent
    // route and tears down the current triage question.
    testWidgets('Back from Q2 navigates to the parent crumb route',
        (WidgetTester tester) async {
      final pumped = await _pumpTriage(tester);

      // Q1: pick option 2 ("Late afternoon / evening") → advance to Q2.
      await tester.tap(find.byKey(TriageScreen.optionKey(0, 2)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(TriageScreen.questionKey(1)), findsOneWidget);

      // Tap the parent crumb ("What's happening?", the segment just
      // before the terminal "Triage" crumb) — the back affordance.
      await tester.tap(find.widgetWithText(InkWell, "What's happening?"));
      await tester.pumpAndSettle();

      // It `context.go`s to the parent route and leaves triage entirely.
      expect(
        pumped.router.routerDelegate.currentConfiguration.uri.toString(),
        '/decoder/behavior',
      );
      expect(find.byType(TriageScreen), findsNothing);
      expect(find.text('test-behavior-picker'), findsOneWidget);
    });

    testWidgets(
      'Back from Q3 navigates to the parent crumb route',
      (WidgetTester tester) async {
        final pumped = await _pumpTriage(tester);

        // Advance Q1 → Q2 → Q3, picking known options at each step.
        await tester.tap(find.byKey(TriageScreen.optionKey(0, 0)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(TriageScreen.nextButtonKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(TriageScreen.optionKey(1, 2)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(TriageScreen.nextButtonKey));
        await tester.pumpAndSettle();
        expect(find.byKey(TriageScreen.questionKey(2)), findsOneWidget);

        // Tap the parent crumb ("What's happening?") — the back
        // affordance; it `context.go`s to `/decoder/behavior`.
        await tester.tap(find.widgetWithText(InkWell, "What's happening?"));
        await tester.pumpAndSettle();

        expect(
          pumped.router.routerDelegate.currentConfiguration.uri.toString(),
          '/decoder/behavior',
        );
        expect(find.byType(TriageScreen), findsNothing);
        expect(find.text('test-behavior-picker'), findsOneWidget);
      },
    );
  });

  group('TriageScreen — Q3 Next navigates to /decoder/result', () {
    testWidgets(
      'pushes /decoder/result with a DecoderResultArgsExtra carrying '
      'the picked behavior + all three answers',
      (WidgetTester tester) async {
        final pumped = await _pumpTriage(tester);

        // Q1: morning
        await tester.tap(find.byKey(TriageScreen.optionKey(0, 0)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(TriageScreen.nextButtonKey));
        await tester.pumpAndSettle();

        // Q2: nothing
        await tester.tap(find.byKey(TriageScreen.optionKey(1, 0)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(TriageScreen.nextButtonKey));
        await tester.pumpAndSettle();

        // Q3: talked
        await tester.tap(find.byKey(TriageScreen.optionKey(2, 0)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(TriageScreen.nextButtonKey));
        await tester.pumpAndSettle();

        expect(pumped.capturedResultExtras, hasLength(1));
        final Object? extra = pumped.capturedResultExtras.single;
        expect(extra, isA<DecoderResultArgsExtra>());
        final DecoderResultArgsExtra args =
            extra! as DecoderResultArgsExtra;
        expect(args.behavior, _sundowning);
        expect(
          args.triage,
          const TriageAnswers(
            when: TriageWhen.morning,
            whatChanged: TriageWhatChanged.nothing,
            whatTried: TriageWhatTried.talked,
          ),
        );
        expect(args.initialAttempt, 0);

        // The stub at /decoder/result rendered, confirming the push
        // landed (not just that the callback fired).
        expect(find.text('test-result'), findsOneWidget);
      },
    );

    testWidgets(
      'free-text path forwards a synthesized non-canonical Behavior',
      (WidgetTester tester) async {
        final pumped =
            await _pumpTriage(tester, args: const TriageArgs.freeText());

        for (int q = 0; q < TriageScreen.totalQuestions; q++) {
          await tester.tap(find.byKey(TriageScreen.optionKey(q, 0)));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(TriageScreen.nextButtonKey));
          await tester.pumpAndSettle();
        }

        expect(pumped.capturedResultExtras, hasLength(1));
        final DecoderResultArgsExtra args =
            pumped.capturedResultExtras.single! as DecoderResultArgsExtra;
        // The synthesized Behavior must NOT be one of the canonical 8 —
        // the LLM call surface keys its free-text vs. canonical branch
        // off `Behavior.byId(id) != null`.
        expect(Behavior.byId(args.behavior.id), isNull);
      },
    );
  });

  group('TriageScreen — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets('Back affordance carries its word label at each step',
        (WidgetTester tester) async {
      await _pumpTriage(tester);

      // The PathHeader replaced the old AppBar back arrow, and the
      // standalone "Back to X" control was then removed too: the back
      // affordance is now the parent breadcrumb crumb ("What's
      // happening?"), a tappable InkWell whose visible Text IS its
      // accessible label for VoiceOver. The crumb trail is stable, not
      // re-framed per step, so assert the word-labeled crumb is present
      // on Q1 …
      expect(
        find.widgetWithText(InkWell, "What's happening?"),
        findsOneWidget,
        reason: 'Q1 Back must surface a word-labeled back affordance',
      );

      // Advance Q1 → Q2 and confirm the word-labeled crumb is still there.
      await tester.tap(find.byKey(TriageScreen.optionKey(0, 0)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(InkWell, "What's happening?"),
        findsOneWidget,
        reason: 'Q2 Back must still surface the word-labeled back affordance',
      );
    });

    testWidgets('Next button announces "Next question" mid-flow and '
        '"Get the script" on the final question',
        (WidgetTester tester) async {
      await _pumpTriage(tester);

      expect(
        hasSemanticsLabel(tester, RegExp('Next question')),
        isTrue,
      );

      // Advance to Q3 (final).
      await tester.tap(find.byKey(TriageScreen.optionKey(0, 0)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TriageScreen.optionKey(1, 0)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();

      expect(
        hasSemanticsLabel(tester, RegExp('Get the script')),
        isTrue,
        reason: 'Q3 Next must speak "Get the script" to signal it submits',
      );
    });

    testWidgets('pill options announce their visible label',
        (WidgetTester tester) async {
      await _pumpTriage(tester);

      expect(
        hasSemanticsLabel(tester, 'Morning'),
        isTrue,
      );
    });
  });

  group('Triage notifier', () {
    test('setters mutate the matching field and leave others untouched', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      final Triage notifier = container.read(triageProvider.notifier);
      expect(container.read(triageProvider), const TriageAnswers());

      notifier.selectWhen(TriageWhen.afternoon);
      expect(container.read(triageProvider).when, TriageWhen.afternoon);
      expect(container.read(triageProvider).whatChanged, isNull);
      expect(container.read(triageProvider).whatTried, isNull);

      notifier.selectWhatChanged(TriageWhatChanged.schedule);
      expect(
        container.read(triageProvider).whatChanged,
        TriageWhatChanged.schedule,
      );
      expect(container.read(triageProvider).when, TriageWhen.afternoon);

      notifier.selectWhatTried(TriageWhatTried.distracted);
      expect(
        container.read(triageProvider),
        const TriageAnswers(
          when: TriageWhen.afternoon,
          whatChanged: TriageWhatChanged.schedule,
          whatTried: TriageWhatTried.distracted,
        ),
      );
    });

    test('reset clears every answer', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      final Triage notifier = container.read(triageProvider.notifier);
      notifier
        ..selectWhen(TriageWhen.night)
        ..selectWhatChanged(TriageWhatChanged.health)
        ..selectWhatTried(TriageWhatTried.walkedAway);
      expect(container.read(triageProvider).when, TriageWhen.night);

      notifier.reset();
      expect(container.read(triageProvider), const TriageAnswers());
    });
  });
}

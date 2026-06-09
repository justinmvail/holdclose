import 'dart:async';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../_semantics_matchers.dart';

/// Pump a minimal router that wraps [BehaviorPickerScreen] and captures
/// the `state.extra` payload pushed to `/decoder/triage`. We don't use
/// the production router here because the goal is to assert what the
/// picker passed forward — a custom stub for the triage route is the
/// cleanest seam.
Future<({GoRouter router, List<Object?> capturedExtras})>
    _pumpPicker(WidgetTester tester) async {
  // Phone-tall surface so all 4 rows of cards lay out within the
  // viewport — tests tap by id and rely on cards being hit-testable
  // without an intermediate `ensureVisible`.
  await tester.binding.setSurfaceSize(const Size(400, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<Object?> capturedExtras = <Object?>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
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
            const BehaviorPickerScreen(),
      ),
      GoRoute(
        path: '/decoder/triage',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) {
          capturedExtras.add(state.extra);
          return const Scaffold(body: Center(child: Text('test-triage')));
        },
      ),
    ],
  );
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();

  // Push the picker onto the root navigator so the PathHeader's parent
  // breadcrumb crumb has somewhere to navigate back to — matching the
  // real navigation pattern from Home (BUILD_SPEC.md §5.1 → §5.2).
  unawaited(router.push('/decoder/behavior'));
  await tester.pumpAndSettle();

  return (router: router, capturedExtras: capturedExtras);
}

void main() {
  group('BehaviorPickerScreen — BUILD_SPEC.md §5.2', () {
    testWidgets('renders the screen with title in the PathHeader',
        (WidgetTester tester) async {
      await _pumpPicker(tester);

      expect(find.byType(BehaviorPickerScreen), findsOneWidget);
      // The screen's title now lives in PathHeader.title (no AppBar).
      // The same string also appears as the terminal breadcrumb crumb,
      // so assert the PathHeader's title property directly to keep this
      // specific to the title (not the crumb) rather than counting Text.
      final PathHeader header =
          tester.widget<PathHeader>(find.byType(PathHeader));
      expect(header.title, "What's happening?");
      // And it is actually painted on screen as Text.
      expect(find.text("What's happening?"), findsWidgets);
    });

    testWidgets('parent breadcrumb crumb provides the back affordance',
        (WidgetTester tester) async {
      await _pumpPicker(tester);

      // No AppBar BackButton and no separate "Back to X" control anymore
      // — the back affordance is the parent breadcrumb crumb, rendered as
      // a tappable InkWell. For this screen (Home › Medical › Journal ›
      // What's happening?) that parent crumb is "Journal".
      expect(find.widgetWithText(InkWell, 'Journal'), findsOneWidget);
    });

    testWidgets('renders all 8 canonical behavior cards with labels',
        (WidgetTester tester) async {
      await _pumpPicker(tester);

      // Sanity-check the canonical list itself — the §5.2 contract is
      // 8 behaviors, no more no less.
      expect(Behavior.canonical, hasLength(8));

      for (final Behavior b in Behavior.canonical) {
        expect(
          find.byKey(BehaviorPickerScreen.cardKey(b.id)),
          findsOneWidget,
          reason: 'card for ${b.id} did not render',
        );
        expect(
          find.text(b.label),
          findsOneWidget,
          reason: 'label "${b.label}" missing',
        );
        expect(
          find.text(b.glyph),
          findsWidgets,
          reason: 'glyph "${b.glyph}" missing for ${b.id}',
        );
      }
    });

    testWidgets('cards exposes the canonical ids from §5.2',
        (WidgetTester tester) async {
      await _pumpPicker(tester);

      const List<String> expectedIds = <String>[
        'upset',
        'refusing_care',
        'wants_home',
        'asking_for_someone',
        'accusing',
        'sundowning',
        'wandering',
        'hallucinating',
      ];

      for (final String id in expectedIds) {
        expect(
          find.byKey(BehaviorPickerScreen.cardKey(id)),
          findsOneWidget,
          reason: 'expected card with id "$id" from §5.2',
        );
      }
    });

    testWidgets('grid is 4×2 (2 columns)', (WidgetTester tester) async {
      await _pumpPicker(tester);

      final GridView grid = tester.widget<GridView>(
        find.byKey(BehaviorPickerScreen.gridKey),
      );
      final SliverGridDelegateWithFixedCrossAxisCount delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 2);
    });

    testWidgets('"Something else — describe it" pill renders below grid',
        (WidgetTester tester) async {
      await _pumpPicker(tester);

      expect(find.byKey(BehaviorPickerScreen.freeTextKey), findsOneWidget);
      expect(find.text('Something else — describe it'), findsOneWidget);
    });
  });

  group('BehaviorPickerScreen — navigation', () {
    testWidgets(
      'tapping each card pushes /decoder/triage with the correct '
      'behavior in extra',
      (WidgetTester tester) async {
        for (final Behavior b in Behavior.canonical) {
          final ({GoRouter router, List<Object?> capturedExtras}) pumped =
              await _pumpPicker(tester);

          await tester.tap(find.byKey(BehaviorPickerScreen.cardKey(b.id)));
          await tester.pumpAndSettle();

          expect(
            pumped.capturedExtras,
            hasLength(1),
            reason: 'tapping ${b.id} should push triage exactly once',
          );
          final Object? extra = pumped.capturedExtras.single;
          expect(
            extra,
            isA<TriageArgs>(),
            reason: 'tapping ${b.id} should push a TriageArgs as extra',
          );
          final TriageArgs args = extra! as TriageArgs;
          expect(args.behavior, b,
              reason: 'tapping ${b.id} should carry the right Behavior');
          expect(args.freeText, isFalse,
              reason: 'canonical card taps must not flag free-text');

          // Confirm the triage stub actually rendered — i.e. the push
          // landed, not just that the callback fired.
          expect(find.text('test-triage'), findsOneWidget);
        }
      },
    );

    testWidgets(
      '"Something else" pushes /decoder/triage with the free-text flag set',
      (WidgetTester tester) async {
        final ({GoRouter router, List<Object?> capturedExtras}) pumped =
            await _pumpPicker(tester);

        await tester.tap(find.byKey(BehaviorPickerScreen.freeTextKey));
        await tester.pumpAndSettle();

        expect(pumped.capturedExtras, hasLength(1));
        final Object? extra = pumped.capturedExtras.single;
        expect(extra, isA<TriageArgs>());
        final TriageArgs args = extra! as TriageArgs;
        expect(args.freeText, isTrue,
            reason: 'free-text pill must flag the free-text path');
        expect(args.behavior, isNull,
            reason: 'free-text path carries no canonical Behavior');

        expect(find.text('test-triage'), findsOneWidget);
      },
    );
  });

  group('BehaviorPickerScreen — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets(
      'every behavior card announces "Behavior: <label>. Double-tap to select."',
      (WidgetTester tester) async {
        await _pumpPicker(tester);

        for (final Behavior b in Behavior.canonical) {
          expect(
            hasSemanticsLabel(
              tester,
              RegExp(
                'Behavior: ${RegExp.escape(b.label)}.*Double-tap to select',
              ),
            ),
            isTrue,
            reason: '${b.id} card must speak its behavior label',
          );
        }
      },
    );

    testWidgets('free-text pill announces the describe-yourself path',
        (WidgetTester tester) async {
      await _pumpPicker(tester);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Something else.*describe the behavior'),
        ),
        isTrue,
      );
    });
  });

  group('TriageArgs equality', () {
    test('forBehavior carries the behavior and clears freeText', () {
      const Behavior sundowning =
          Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅');
      const TriageArgs a = TriageArgs.forBehavior(sundowning);

      expect(a.behavior, sundowning);
      expect(a.freeText, isFalse);
    });

    test('freeText carries no behavior and sets the flag', () {
      const TriageArgs args = TriageArgs.freeText();

      expect(args.behavior, isNull);
      expect(args.freeText, isTrue);
    });

    test('value equality between identical args', () {
      const Behavior accusing =
          Behavior(id: 'accusing', label: 'Accusing me', glyph: '💸');
      const TriageArgs a1 = TriageArgs.forBehavior(accusing);
      const TriageArgs a2 = TriageArgs.forBehavior(accusing);
      const TriageArgs f1 = TriageArgs.freeText();
      const TriageArgs f2 = TriageArgs.freeText();

      expect(a1, equals(a2));
      expect(a1.hashCode, equals(a2.hashCode));
      expect(f1, equals(f2));
      expect(a1, isNot(equals(f1)));
    });
  });
}

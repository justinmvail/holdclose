import 'package:careblazers/screens/library/library_card_screen.dart';
import 'package:careblazers/screens/library/library_screen.dart';
import 'package:careblazers/seed/library_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../_semantics_matchers.dart';

/// Fixed clock used by every test that doesn't care about the day-of-
/// year rotation specifically — pinned to BUILD_SPEC's "currentDate"
/// (2026-05-29) for parity with the rest of the test suite.
final DateTime _fixedNow = DateTime(2026, 5, 29, 12, 0);

/// Build a minimal router that wraps [LibraryScreen] and a stub
/// `/library/:id` detail. We don't use the production router because
/// the LibraryCardScreen builder is still a placeholder and we want a
/// clean assertion target — taps land on a known stub that captures
/// the pushed id.
Future<({GoRouter router, List<String> pushedIds})> _pumpLibrary(
  WidgetTester tester, {
  DateTime? now,
}) async {
  // Tall surface so the full populated layout (today's card + two
  // sections + 9 tiles) lays out inside the viewport. ListView with
  // explicit children still mounts lazily under SliverList, so a tile
  // that lands below the viewport + cacheExtent never enters the
  // element tree and `find.byKey` would silently miss it. Some hooks
  // wrap to a second line and `caregiver_guilt`'s title wraps to
  // three — leave plenty of headroom rather than tune it close.
  await tester.binding.setSurfaceSize(const Size(420, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> pushedIds = <String>[];
  final GoRouter router = GoRouter(
    initialLocation: '/library',
    routes: <RouteBase>[
      GoRoute(
        path: '/library',
        builder: (BuildContext context, GoRouterState state) =>
            const LibraryScreen(),
      ),
      GoRoute(
        path: '/library/:id',
        name: 'library-card',
        builder: (BuildContext context, GoRouterState state) {
          final String id = state.pathParameters['id'] ?? '';
          pushedIds.add(id);
          return LibraryCardScreen(cardId: id);
        },
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        libraryScreenClockProvider.overrideWithValue(() => now ?? _fixedNow),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  return (router: router, pushedIds: pushedIds);
}

void main() {
  group('LibraryScreen — BUILD_SPEC.md §5.7', () {
    testWidgets('AppBar title is "Library" and has no BackButton',
        (WidgetTester tester) async {
      await _pumpLibrary(tester);

      expect(find.widgetWithText(AppBar, 'Library'), findsOneWidget);
      // Library is a tab root — never an auto back arrow.
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets("renders the 'Today's card' hero", (WidgetTester tester) async {
      await _pumpLibrary(tester);

      expect(find.byKey(LibraryScreen.todaysCardKey), findsOneWidget);
      expect(find.text("Today's card"), findsOneWidget);
    });

    testWidgets('renders both section headers in spec order',
        (WidgetTester tester) async {
      await _pumpLibrary(tester);

      expect(find.byKey(LibraryScreen.mostAskedSectionKey), findsOneWidget);
      expect(find.byKey(LibraryScreen.caregiverSectionKey), findsOneWidget);
      expect(find.text('Most-asked behaviors'), findsOneWidget);
      expect(find.text('For YOU, the caregiver'), findsOneWidget);

      // Visual top-down ordering: the hero sits above 'Most-asked', and
      // 'Most-asked' sits above 'For YOU' (BUILD_SPEC.md §5.7).
      double y(Key k) => tester.getTopLeft(find.byKey(k)).dy;
      expect(
        y(LibraryScreen.todaysCardKey),
        lessThan(y(LibraryScreen.mostAskedSectionKey)),
      );
      expect(
        y(LibraryScreen.mostAskedSectionKey),
        lessThan(y(LibraryScreen.caregiverSectionKey)),
      );
    });

    testWidgets('renders every card tile in the fixed sections',
        (WidgetTester tester) async {
      await _pumpLibrary(tester);

      for (final String id in mostAskedBehaviorCardIds) {
        expect(
          find.byKey(LibraryScreen.cardTileKey(id)),
          findsOneWidget,
          reason: 'most-asked card "$id" did not render',
        );
      }
      for (final String id in caregiverCardIds) {
        expect(
          find.byKey(LibraryScreen.cardTileKey(id)),
          findsOneWidget,
          reason: 'caregiver card "$id" did not render',
        );
      }
    });

    testWidgets('fixed section ids only reference real seed cards', (
      WidgetTester tester,
    ) async {
      // Sanity guard: a typo in [mostAskedBehaviorCardIds] /
      // [caregiverCardIds] would surface here long before the user
      // hit a `null` dereference at runtime.
      for (final String id in mostAskedBehaviorCardIds) {
        expect(
          libraryCardById(id),
          isNotNull,
          reason: '"$id" in mostAskedBehaviorCardIds is not a real card',
        );
      }
      for (final String id in caregiverCardIds) {
        expect(
          libraryCardById(id),
          isNotNull,
          reason: '"$id" in caregiverCardIds is not a real card',
        );
      }
    });
  });

  group("LibraryScreen — Today's card determinism", () {
    test('todaysCardIndex matches (dayOfYear % 12) for January 1st', () {
      // Jan 1 is day-of-year 1 → 1 % 12 = 1.
      const int expected = 1 % 12;
      expect(
        LibraryScreen.todaysCardIndex(DateTime(2026, 1, 1, 9, 30)),
        expected,
      );
    });

    test('todaysCardIndex matches (dayOfYear % 12) for May 29', () {
      // May 29, 2026 → day-of-year 149 → 149 % 12 = 5.
      expect(
        LibraryScreen.todaysCardIndex(DateTime(2026, 5, 29, 12, 0)),
        149 % 12,
      );
    });

    test('todaysCardIndex is stable across times-of-day on the same date', () {
      final DateTime morning = DateTime(2026, 3, 15, 7, 5);
      final DateTime evening = DateTime(2026, 3, 15, 22, 45);

      expect(
        LibraryScreen.todaysCardIndex(morning),
        LibraryScreen.todaysCardIndex(evening),
      );
    });

    test('todaysCardIndex returns a valid index into libraryCards', () {
      // Spot-check several dates across the year, including a leap day,
      // to confirm the modulo stays in range no matter the input.
      final List<DateTime> spotChecks = <DateTime>[
        DateTime(2026, 1, 1),
        DateTime(2024, 2, 29), // leap day
        DateTime(2026, 7, 4),
        DateTime(2026, 12, 31),
      ];
      for (final DateTime d in spotChecks) {
        final int idx = LibraryScreen.todaysCardIndex(d);
        expect(idx, inInclusiveRange(0, libraryCards.length - 1));
      }
    });

    testWidgets('renders the deterministic card for a pinned date', (
      WidgetTester tester,
    ) async {
      final DateTime pinned = DateTime(2026, 5, 29, 12, 0);
      final LibraryCard expected = LibraryScreen.todaysCard(pinned);

      await _pumpLibrary(tester, now: pinned);

      // The hero shows the card's title and hook.
      expect(find.text(expected.title), findsWidgets);
      expect(find.text(expected.hook), findsWidgets);
    });

    testWidgets('the hero updates when the clock advances by one day', (
      WidgetTester tester,
    ) async {
      // Pick two dates whose dayOfYear values mod 12 differ — adjacent
      // days in March, days 74 and 75. 74 % 12 = 2; 75 % 12 = 3.
      final DateTime dayA = DateTime(2026, 3, 15, 12, 0);
      final DateTime dayB = DateTime(2026, 3, 16, 12, 0);
      assert(
        LibraryScreen.todaysCardIndex(dayA) !=
            LibraryScreen.todaysCardIndex(dayB),
        'precondition: adjacent days picked to land on different '
        'rotation indices',
      );

      await _pumpLibrary(tester, now: dayA);
      final LibraryCard cardA = LibraryScreen.todaysCard(dayA);
      expect(find.text(cardA.title), findsWidgets);

      await _pumpLibrary(tester, now: dayB);
      final LibraryCard cardB = LibraryScreen.todaysCard(dayB);
      expect(find.text(cardB.title), findsWidgets);
      expect(cardA.id, isNot(cardB.id));
    });
  });

  group('LibraryScreen — navigation', () {
    testWidgets("tapping today's card pushes /library/:id with the right id",
        (WidgetTester tester) async {
      final DateTime pinned = DateTime(2026, 5, 29, 12, 0);
      final LibraryCard expected = LibraryScreen.todaysCard(pinned);

      final ({GoRouter router, List<String> pushedIds}) pumped =
          await _pumpLibrary(tester, now: pinned);

      await tester.tap(find.byKey(LibraryScreen.todaysCardKey));
      await tester.pumpAndSettle();

      expect(pumped.pushedIds, <String>[expected.id]);
      expect(find.byType(LibraryCardScreen), findsOneWidget);
      final LibraryCardScreen pushed = tester.widget<LibraryCardScreen>(
        find.byType(LibraryCardScreen),
      );
      expect(pushed.cardId, expected.id);
    });

    testWidgets(
      "tapping every fixed-section card pushes /library/:id with its id",
      (WidgetTester tester) async {
        for (final String id in <String>[
          ...mostAskedBehaviorCardIds,
          ...caregiverCardIds,
        ]) {
          final ({GoRouter router, List<String> pushedIds}) pumped =
              await _pumpLibrary(tester);

          // Each tile sits inside a ListView. Some cards land below the
          // initial viewport on a phone-sized surface — scroll them into
          // view before tapping to keep the test deterministic regardless
          // of tile height.
          await tester.ensureVisible(
            find.byKey(LibraryScreen.cardTileKey(id)),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(LibraryScreen.cardTileKey(id)));
          await tester.pumpAndSettle();

          expect(
            pumped.pushedIds,
            <String>[id],
            reason: 'tapping tile "$id" should push exactly /library/$id',
          );
          expect(find.byType(LibraryCardScreen), findsOneWidget);
          final LibraryCardScreen pushed = tester.widget<LibraryCardScreen>(
            find.byType(LibraryCardScreen),
          );
          expect(pushed.cardId, id);
        }
      },
    );
  });

  group('LibraryScreen — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets("today's card hero announces the card title",
        (WidgetTester tester) async {
      final DateTime pinned = DateTime(2026, 5, 29, 12, 0);
      final LibraryCard expected = LibraryScreen.todaysCard(pinned);

      await _pumpLibrary(tester, now: pinned);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp(
            "Today's card: ${RegExp.escape(expected.title)}.*Double-tap to read",
          ),
        ),
        isTrue,
      );
    });

    testWidgets('every card tile announces its title',
        (WidgetTester tester) async {
      await _pumpLibrary(tester);

      for (final String id in mostAskedBehaviorCardIds) {
        await tester.ensureVisible(find.byKey(LibraryScreen.cardTileKey(id)));
        await tester.pumpAndSettle();

        expect(
          hasSemanticsLabel(
            tester,
            RegExp(
              '${RegExp.escape(libraryCardById(id)!.title)}.*Double-tap to read',
            ),
          ),
          isTrue,
          reason: 'tile "$id" must announce its title',
        );
      }
    });
  });

  group('Fixed section composition', () {
    test('"Most-asked behaviors" lists six cards in spec order', () {
      // BUILD_SPEC.md §5.7 lists six items under this header. Order
      // here matches the spec listing top-to-bottom.
      expect(mostAskedBehaviorCardIds, hasLength(6));
      expect(
        mostAskedBehaviorCardIds,
        const <String>[
          'sundowning_basics',
          'anosognosia',
          'family_doesnt_believe',
          'accusations_basics',
          'five_causes',
          'step_into_reality',
        ],
      );
    });

    test('"For YOU, the caregiver" lists three cards in spec order', () {
      expect(caregiverCardIds, hasLength(3));
      expect(
        caregiverCardIds,
        const <String>[
          'caregiver_guilt',
          'boundaries_compassion',
          'when_to_ask_respite',
        ],
      );
    });

    test('no card appears in both fixed sections', () {
      final Set<String> a = mostAskedBehaviorCardIds.toSet();
      final Set<String> b = caregiverCardIds.toSet();
      expect(a.intersection(b), isEmpty);
    });
  });
}

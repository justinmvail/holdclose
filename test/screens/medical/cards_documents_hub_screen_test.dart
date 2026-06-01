import 'package:careblazers/screens/medical/cards_documents_hub_screen.dart';
import 'package:careblazers/widgets/hub_tile.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The three tiles in their documented order (BUILD_SPEC.md §5.13,
/// TASKS.md Phase 14.22): (label, icon, route).
const List<(String, IconData, String)> _expected = <(String, IconData, String)>[
  ('Emergency Card', Icons.emergency_outlined, '/medical/cards/emergency'),
  ('Power of Attorney', Icons.gavel_outlined, '/medical/cards/poa'),
  ('Identification', Icons.badge_outlined, '/medical/cards/ids'),
];

/// A router that mounts the hub at `/medical/cards` (under a `/medical`
/// parent so the `Home › Medical` breadcrumb + Back control resolve) and
/// registers a stub destination for every tile route so a `context.push`
/// resolves end to end. The Power of Attorney + Identification pages land
/// in later phases; here we only assert the navigation target is correct.
GoRouter _router() {
  return GoRouter(
    initialLocation: '/medical/cards',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('DEST /'))),
      ),
      GoRoute(
        path: '/medical',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('DEST /medical'))),
      ),
      GoRoute(
        path: '/medical/cards',
        builder: (BuildContext context, GoRouterState state) =>
            const CardsDocumentsHubScreen(),
      ),
      for (final (_, _, String route) in _expected)
        GoRoute(
          path: route,
          builder: (BuildContext context, GoRouterState state) => Scaffold(
            body: Center(child: Text('DEST $route')),
          ),
        ),
    ],
  );
}

/// Pumps the hub at a tall phone surface so all three tiles render inside
/// the viewport. We deliberately skip `careblazersLightTheme` — its
/// google_fonts TextStyles fire fire-and-forget Futures that surface as
/// uncaught errors in a font-less test host; the screen re-applies its
/// brand colors directly, so navigation behavior is unaffected.
Future<GoRouter> _pumpHub(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(412, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = _router();
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('CardsDocumentsHubScreen', () {
    testWidgets('renders all three tiles in the documented order',
        (WidgetTester tester) async {
      await _pumpHub(tester);

      final List<HubTile> tiles =
          tester.widgetList<HubTile>(find.byType(HubTile)).toList();
      expect(tiles.length, 3);
      expect(
        tiles.map((HubTile t) => t.label).toList(),
        <String>[for (final (String label, _, _) in _expected) label],
      );
      expect(
        tiles.map((HubTile t) => t.icon).toList(),
        <IconData>[for (final (_, IconData icon, _) in _expected) icon],
      );
    });

    testWidgets('is a nested hub — shows the Home › Medical trail + Back',
        (WidgetTester tester) async {
      await _pumpHub(tester);

      expect(find.byType(PathHeader), findsOneWidget);
      // Title + both routed crumbs render...
      expect(find.text('Cards & Documents'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Medical'), findsOneWidget);
      // ...the trail separator + Back chevron prove this is NOT a
      // single-crumb landing.
      expect(find.text('›'), findsOneWidget);
      expect(find.text('‹'), findsOneWidget);
      expect(find.text('Back to Medical'), findsOneWidget);
    });

    testWidgets('Back control returns to Medical',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpHub(tester);

      await tester.tap(find.text('Back to Medical'));
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.last.matchedLocation,
        '/medical',
      );
      expect(find.text('DEST /medical'), findsOneWidget);
    });

    testWidgets('Medical crumb navigates up to Medical',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpHub(tester);

      await tester.tap(find.text('Medical'));
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.last.matchedLocation,
        '/medical',
      );
    });

    for (final (String label, _, String route) in _expected) {
      testWidgets('tapping "$label" pushes $route',
          (WidgetTester tester) async {
        final GoRouter router = await _pumpHub(tester);

        await tester.ensureVisible(
          find.byKey(CardsDocumentsHubScreen.tileKey(route)),
        );
        await tester.tap(find.byKey(CardsDocumentsHubScreen.tileKey(route)));
        await tester.pumpAndSettle();

        // A tile `context.push`es its route — the imperative push keeps
        // the base URI but appends the pushed match, so assert on the last
        // matched location (and the rendered destination).
        expect(
          router.routerDelegate.currentConfiguration.last.matchedLocation,
          route,
        );
        expect(find.text('DEST $route'), findsOneWidget);
      });
    }
  });
}

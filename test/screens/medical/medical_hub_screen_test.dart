import 'package:holdclose/screens/medical/medical_hub_screen.dart';
import 'package:holdclose/widgets/hub_tile.dart';
import 'package:holdclose/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The eleven tiles in their display order: (label, icon, route).
///
/// **Emergency Card leads** (UIUX_REVIEW) — the highest-stakes glanceable
/// surface — and the **Care Circle** tile is always present (the door to
/// inviting family stays discoverable; the `/team` sub-hub itself handles
/// the coordination-off onboarding). Neither is gated by the Settings
/// toggle anymore.
///
/// `route` is the exact string each tile `context.push`es — it doubles as
/// the per-tile [MedicalHubScreen.tileKey] seed, so it must match the
/// screen verbatim. The "Schedule" tile reuses the shared calendar screen
/// but tags the push with `?from=medical`; the query string rides along on
/// the pushed URI but is not part of the matched route path (see
/// [_matchedPath]).
const List<(String, IconData, String)> _expected = <(String, IconData, String)>[
  ('Emergency Card', Icons.shield_outlined, '/medical/cards/emergency'),
  ('Medications', Icons.medication_outlined, '/medications'),
  ('Scan a document', Icons.document_scanner_outlined, '/scan'),
  ('Find a provider', Icons.person_search_outlined, '/find-provider'),
  ('Care summary', Icons.summarize_outlined, '/care-summary'),
  ('Schedule', Icons.schedule_outlined, '/team/calendar?from=medical'),
  ('Appointments', Icons.event_outlined, '/appointments'),
  ('Health Log', Icons.monitor_heart_outlined, '/medical/health-log'),
  ('Routines', Icons.assignment_outlined, '/medical/routines'),
  ('Journal', Icons.book_outlined, '/journal'),
  ('Care Circle', Icons.diversity_3_outlined, '/team'),
];

/// The route path a tile resolves to, with any `?query` stripped. A
/// `GoRoute` is registered by path (a query string is not a valid path
/// pattern), and `matchedLocation` likewise reports the path only — the
/// query params live on the URI separately. So a tile that pushes
/// `/team/calendar?from=medical` matches the `/team/calendar` route.
String _matchedPath(String route) => Uri.parse(route).path;

/// A router that mounts the hub at `/medical` and registers a stub
/// destination for every tile route so a `context.push` resolves end to
/// end. The destinations the hub points at land in later phases; here we
/// only assert the navigation target is correct.
GoRouter _router() {
  return GoRouter(
    initialLocation: '/medical',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical',
        builder: (BuildContext context, GoRouterState state) =>
            const MedicalHubScreen(),
      ),
      for (final (_, _, String route) in _expected)
        GoRoute(
          path: _matchedPath(route),
          builder: (BuildContext context, GoRouterState state) => Scaffold(
            body: Center(child: Text('DEST ${_matchedPath(route)}')),
          ),
        ),
    ],
  );
}

/// Pumps the hub at a tall phone surface so all tiles render inside the
/// viewport (the grid scrolls, but a tall surface keeps every tile
/// hittable). [MedicalHubScreen] is a plain StatelessWidget now (the tile
/// list no longer reads settings), so no ProviderScope is needed. We
/// deliberately skip `holdcloseLightTheme` — its google_fonts TextStyles
/// fire fire-and-forget Futures that surface as uncaught errors in a
/// font-less test host; the screen re-applies its brand colors directly,
/// so navigation behavior is unaffected.
Future<GoRouter> _pumpHub(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(412, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = _router();
  await tester.pumpWidget(
    MaterialApp.router(routerConfig: router),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('MedicalHubScreen', () {
    testWidgets(
        'renders all eleven tiles in order, Emergency Card first',
        (WidgetTester tester) async {
      await _pumpHub(tester);

      final List<HubTile> tiles =
          tester.widgetList<HubTile>(find.byType(HubTile)).toList();
      expect(tiles.length, 11);
      // Emergency Card leads the grid (UIUX_REVIEW).
      expect(tiles.first.label, 'Emergency Card');
      expect(
        tiles.map((HubTile t) => t.label).toList(),
        <String>[for (final (String label, _, _) in _expected) label],
      );
      expect(
        tiles.map((HubTile t) => t.icon).toList(),
        <IconData>[for (final (_, IconData icon, _) in _expected) icon],
      );
    });

    testWidgets('the Find-a-provider tile uses plain-language, not "NPI"',
        (WidgetTester tester) async {
      await _pumpHub(tester);

      final HubTile provider = tester
          .widgetList<HubTile>(find.byType(HubTile))
          .firstWhere((HubTile t) => t.label == 'Find a provider');
      expect(provider.subLabel, 'doctors & specialists');
      expect(find.textContaining('NPI'), findsNothing);
    });

    testWidgets('the landing breadcrumb starts from Home (Home › Care)',
        (WidgetTester tester) async {
      await _pumpHub(tester);

      // Every page's trail starts at Home now, so the Care landing reads
      // "Home › Care" rather than suppressing the breadcrumb.
      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('›'), findsOneWidget); // Home › Care
      // 'Care' is both the title and the terminal crumb.
      expect(find.text('Care'), findsNWidgets(2));
      // No legacy Back chevron control.
      expect(find.text('‹'), findsNothing);
    });

    testWidgets(
        'the Care Circle tile is always present with an inviting sub-label',
        (WidgetTester tester) async {
      // No longer gated on the Settings toggle (UIUX_REVIEW) — the door to
      // inviting family stays discoverable regardless of coordination state.
      await _pumpHub(tester);

      final List<HubTile> tiles =
          tester.widgetList<HubTile>(find.byType(HubTile)).toList();
      final HubTile careCircle =
          tiles.firstWhere((HubTile t) => t.label == 'Care Circle');
      expect(careCircle.subLabel, 'invite family to share the load');
      expect(
        find.byKey(MedicalHubScreen.tileKey('/team')),
        findsOneWidget,
      );
    });

    for (final (String label, _, String route) in _expected) {
      testWidgets('tapping "$label" pushes $route',
          (WidgetTester tester) async {
        final GoRouter router = await _pumpHub(tester);

        await tester.ensureVisible(
          find.byKey(MedicalHubScreen.tileKey(route)),
        );
        await tester.tap(find.byKey(MedicalHubScreen.tileKey(route)));
        await tester.pumpAndSettle();

        // A tile `context.push`es its route — the imperative push keeps
        // the shell's base URI but appends the pushed match, so assert on
        // the last matched location (and the rendered destination). The
        // matched location is the route *path*; a tile that pushes a
        // `?query` (Schedule's `?from=medical`) still resolves to its
        // bare-path route, so compare against [_matchedPath].
        expect(
          router.routerDelegate.currentConfiguration.last.matchedLocation,
          _matchedPath(route),
        );
        expect(find.text('DEST ${_matchedPath(route)}'), findsOneWidget);
      });
    }
  });
}

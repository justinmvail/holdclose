import 'package:holdclose/models/settings.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/medical/medical_hub_screen.dart';
import 'package:holdclose/widgets/hub_tile.dart';
import 'package:holdclose/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The seven tiles in their documented order (BUILD_SPEC.md §5.13,
/// TASKS.md Phase 14.15): (label, icon, route). This is the default
/// (team-coordination off) tile set; the gated **Care Circle** tile is a
/// trailing eighth that only appears when the toggle is on (asserted
/// separately below).
///
/// `route` is the exact string each tile `context.push`es — it doubles as
/// the per-tile [MedicalHubScreen.tileKey] seed, so it must match the
/// screen verbatim. The "Schedule" tile reuses the shared calendar screen
/// but tags the push with `?from=medical`; the query string rides along on
/// the pushed URI but is not part of the matched route path (see
/// [_matchedPath]).
const List<(String, IconData, String)> _expected = <(String, IconData, String)>[
  ('Scan a document', Icons.document_scanner_outlined, '/scan'),
  ('Find a provider', Icons.person_search_outlined, '/find-provider'),
  ('Care summary', Icons.summarize_outlined, '/care-summary'),
  ('Medications', Icons.medication_outlined, '/medications'),
  ('Schedule', Icons.schedule_outlined, '/team/calendar?from=medical'),
  ('Appointments', Icons.event_outlined, '/appointments'),
  ('Health Log', Icons.monitor_heart_outlined, '/medical/health-log'),
  ('Routines', Icons.assignment_outlined, '/medical/routines'),
  ('Emergency Card', Icons.shield_outlined, '/medical/cards/emergency'),
  ('Journal', Icons.book_outlined, '/journal'),
];

/// The route path a tile resolves to, with any `?query` stripped. A
/// `GoRoute` is registered by path (a query string is not a valid path
/// pattern), and `matchedLocation` likewise reports the path only — the
/// query params live on the URI separately. So a tile that pushes
/// `/team/calendar?from=medical` matches the `/team/calendar` route.
String _matchedPath(String route) => Uri.parse(route).path;

/// A router that mounts the hub at `/medical` and registers a stub
/// destination for every tile route so a `context.push` resolves end to
/// end (plus the gated Care Circle `/team` route). The destinations the
/// hub points at land in later phases; here we only assert the navigation
/// target is correct.
GoRouter _router() {
  return GoRouter(
    initialLocation: '/medical',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical',
        builder: (BuildContext context, GoRouterState state) =>
            const MedicalHubScreen(),
      ),
      GoRoute(
        path: '/team',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('DEST /team'))),
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

/// An in-memory store pre-seeded with [teamEnabled] coordination so the
/// settings provider hydrates into the right state on first pump. The
/// default (`false`) keeps the hub at its seven base tiles; `true` adds
/// the trailing Care Circle tile.
InMemoryStorageProvider _seededStorage({required bool teamEnabled}) {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  storage.updateSettings(
    AppSettings.defaults().copyWith(teamCoordinationEnabled: teamEnabled),
  );
  return storage;
}

/// Pumps the hub at a tall phone surface so all tiles render inside the
/// viewport (the grid scrolls, but a tall surface keeps every tile
/// hittable). [MedicalHubScreen] is a ConsumerWidget that reads
/// `settingsProvider`, so it's wrapped in a ProviderScope with the
/// storage seam overridden to drive the team-coordination toggle. We
/// deliberately skip `holdcloseLightTheme` — its google_fonts
/// TextStyles fire fire-and-forget Futures that surface as uncaught
/// errors in a font-less test host; the screen re-applies its brand
/// colors directly, so navigation behavior is unaffected.
Future<GoRouter> _pumpHub(
  WidgetTester tester, {
  bool teamEnabled = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(412, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = _router();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageProvider.overrideWithValue(
          _seededStorage(teamEnabled: teamEnabled),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('MedicalHubScreen', () {
    testWidgets('renders all seven tiles in the documented order',
        (WidgetTester tester) async {
      await _pumpHub(tester);

      final List<HubTile> tiles =
          tester.widgetList<HubTile>(find.byType(HubTile)).toList();
      expect(tiles.length, 10);
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
        'with team coordination on, a trailing Care Circle tile appears',
        (WidgetTester tester) async {
      await _pumpHub(tester, teamEnabled: true);

      final List<HubTile> tiles =
          tester.widgetList<HubTile>(find.byType(HubTile)).toList();
      // The base tiles plus the gated Care Circle tile (route /team).
      expect(tiles.length, 11);
      expect(tiles.last.label, 'Care Circle');
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

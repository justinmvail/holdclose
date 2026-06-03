import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/team/care_team_hub_screen.dart';
import 'package:careblazers/widgets/hub_tile.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The six tiles in their documented order (BUILD_SPEC.md §5.13,
/// TASKS.md Phase 14.26): (label, icon, route).
const List<(String, IconData, String)> _expected = <(String, IconData, String)>[
  ('Calendar', Icons.calendar_view_week_outlined, '/team/calendar'),
  ('Tasks', Icons.task_alt_outlined, '/team/tasks'),
  ('Shifts', Icons.access_time_outlined, '/team/shifts'),
  ('Care Circle', Icons.diversity_3_outlined, '/team/circle'),
  ('Activity', Icons.timeline_outlined, '/team/activity'),
  ('Expenses', Icons.account_balance_wallet_outlined, '/team/expenses'),
];

/// A router that mounts the hub at `/team` and registers a stub
/// destination for every tile route so a `context.push` resolves end to
/// end. The destinations the hub points at land in later phases; here we
/// only assert the navigation target is correct.
GoRouter _router() {
  return GoRouter(
    initialLocation: '/team',
    routes: <RouteBase>[
      GoRoute(
        path: '/team',
        builder: (BuildContext context, GoRouterState state) =>
            const CareTeamHubScreen(),
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

/// Pre-seed a fake storage with [teamEnabled] coordination so the
/// settings provider's microtask hydrates into the right state on first
/// pump. Without this the default is `false` and the hub would render
/// the empty-state CTA instead of the tile grid.
InMemoryStorageProvider _seededStorage({required bool teamEnabled}) {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  storage.updateSettings(
    AppSettings.defaults().copyWith(teamCoordinationEnabled: teamEnabled),
  );
  return storage;
}

/// Pumps the hub at a tall phone surface so all six tiles render inside
/// the viewport (the grid scrolls, but a tall surface keeps every tile
/// hittable). We deliberately skip `careblazersLightTheme` — its
/// google_fonts TextStyles fire fire-and-forget Futures that surface as
/// uncaught errors in a font-less test host; the screen re-applies its
/// brand colors directly, so navigation behavior is unaffected.
Future<GoRouter> _pumpHub(
  WidgetTester tester, {
  bool teamEnabled = true,
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
  group('CareTeamHubScreen — coordination enabled', () {
    testWidgets('renders all six tiles in the documented order',
        (WidgetTester tester) async {
      await _pumpHub(tester);

      final List<HubTile> tiles =
          tester.widgetList<HubTile>(find.byType(HubTile)).toList();
      expect(tiles.length, 6);
      expect(
        tiles.map((HubTile t) => t.label).toList(),
        <String>[for (final (String label, _, _) in _expected) label],
      );
      expect(
        tiles.map((HubTile t) => t.icon).toList(),
        <IconData>[for (final (_, IconData icon, _) in _expected) icon],
      );
    });

    testWidgets('is a landing screen — no breadcrumb, no Back control',
        (WidgetTester tester) async {
      await _pumpHub(tester);

      // The PathHeader is present with the single "Care Team" crumb...
      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Care Team'), findsOneWidget);
      // ...but a single-crumb landing suppresses the trail + Back chip.
      expect(find.text('›'), findsNothing);
      expect(find.text('‹'), findsNothing);
    });

    for (final (String label, _, String route) in _expected) {
      testWidgets('tapping "$label" pushes $route',
          (WidgetTester tester) async {
        final GoRouter router = await _pumpHub(tester);

        await tester.ensureVisible(
          find.byKey(CareTeamHubScreen.tileKey(route)),
        );
        await tester.tap(find.byKey(CareTeamHubScreen.tileKey(route)));
        await tester.pumpAndSettle();

        // A tile `context.push`es its route — the imperative push keeps
        // the shell's base URI but appends the pushed match, so assert on
        // the last matched location (and the rendered destination).
        expect(
          router.routerDelegate.currentConfiguration.last.matchedLocation,
          route,
        );
        expect(find.text('DEST $route'), findsOneWidget);
      });
    }
  });

  group('CareTeamHubScreen — coordination disabled (default)', () {
    testWidgets('shows the "Coordinate care" CTA, not the tile grid',
        (WidgetTester tester) async {
      await _pumpHub(tester, teamEnabled: false);

      expect(find.byType(HubTile), findsNothing);
      expect(find.byKey(CareTeamHubScreen.emptyStateKey), findsOneWidget);
      expect(find.byKey(CareTeamHubScreen.enableCtaKey), findsOneWidget);
      // The PathHeader still renders — the tab stays mounted either way.
      expect(find.byType(PathHeader), findsOneWidget);
    });

    testWidgets('tapping the CTA flips the toggle and reveals the tiles',
        (WidgetTester tester) async {
      await _pumpHub(tester, teamEnabled: false);

      await tester.tap(find.byKey(CareTeamHubScreen.enableCtaKey));
      await tester.pumpAndSettle();

      expect(find.byKey(CareTeamHubScreen.emptyStateKey), findsNothing);
      expect(find.byType(HubTile), findsNWidgets(_expected.length));
    });
  });
}

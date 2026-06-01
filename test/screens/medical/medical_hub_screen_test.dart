import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/widgets/hub_tile.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The seven tiles in their documented order (BUILD_SPEC.md §5.13,
/// TASKS.md Phase 14.15): (label, icon, route).
const List<(String, IconData, String)> _expected = <(String, IconData, String)>[
  ('Medications', Icons.medication_outlined, '/medications'),
  ('Med Schedule', Icons.schedule_outlined, '/medical/schedule'),
  ('Appointments', Icons.event_outlined, '/appointments'),
  ('Health Log', Icons.monitor_heart_outlined, '/medical/health-log'),
  ('Care Plan', Icons.assignment_outlined, '/medical/care-plan'),
  ('Cards & Docs', Icons.badge_outlined, '/medical/cards'),
  ('Journal', Icons.book_outlined, '/journal'),
];

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
          path: route,
          builder: (BuildContext context, GoRouterState state) => Scaffold(
            body: Center(child: Text('DEST $route')),
          ),
        ),
    ],
  );
}

/// Pumps the hub at a tall phone surface so all seven tiles render inside
/// the viewport (the grid scrolls, but a tall surface keeps every tile
/// hittable). We deliberately skip `careblazersLightTheme` — its
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
  group('MedicalHubScreen', () {
    testWidgets('renders all seven tiles in the documented order',
        (WidgetTester tester) async {
      await _pumpHub(tester);

      final List<HubTile> tiles =
          tester.widgetList<HubTile>(find.byType(HubTile)).toList();
      expect(tiles.length, 7);
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

      // The PathHeader is present with the single "Medical" crumb...
      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Medical'), findsOneWidget);
      // ...but a single-crumb landing suppresses the trail + Back chip.
      expect(find.text('›'), findsNothing);
      expect(find.text('‹'), findsNothing);
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
        // the last matched location (and the rendered destination).
        expect(
          router.routerDelegate.currentConfiguration.last.matchedLocation,
          route,
        );
        expect(find.text('DEST $route'), findsOneWidget);
      });
    }
  });
}

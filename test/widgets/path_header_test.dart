import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Builds a tiny GoRouter whose deep `/medical/medications` location
/// hosts the [header], so `context.go` / `context.pop` resolve against a
/// real navigator. Parent routes render a labeled placeholder we can
/// assert on after a crumb tap.
GoRouter _routerHosting(
  PathHeader header, {
  String initialLocation = '/medical/medications',
}) {
  Widget page(String label, [Widget? body]) => Scaffold(
        body: body ?? Center(child: Text(label)),
      );
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(path: '/', builder: (_, __) => page('HOME PAGE')),
      GoRoute(path: '/medical', builder: (_, __) => page('MEDICAL PAGE')),
      GoRoute(
        path: '/medical/medications',
        builder: (_, __) => page('MEDS PAGE', header),
      ),
    ],
  );
}

Future<void> _pumpRouter(WidgetTester tester, GoRouter router) async {
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

const List<PathHeaderCrumb> _threeCrumbs = <PathHeaderCrumb>[
  PathHeaderCrumb(label: 'Home', route: '/'),
  PathHeaderCrumb(label: 'Medical', route: '/medical'),
  PathHeaderCrumb(label: 'Medications'),
];

void main() {
  group('PathHeader — rendering', () {
    testWidgets('renders breadcrumb trail with › separators + title',
        (WidgetTester tester) async {
      await _pumpRouter(
        tester,
        _routerHosting(const PathHeader(
          breadcrumbs: _threeCrumbs,
          title: 'Medications',
          backLabel: 'Back to Medical',
          leadingIcon: Icons.medication_outlined,
        )),
      );

      expect(find.text('Home'), findsOneWidget);
      // The parent 'Medical' crumb is the back affordance (the separate
      // "Back to X" control was removed) — it renders as a tappable crumb.
      expect(find.widgetWithText(InkWell, 'Medical'), findsOneWidget);
      // 'Medications' appears as both the terminal crumb and the title.
      expect(find.text('Medications'), findsNWidgets(2));
      // Two separators for three crumbs.
      expect(find.text('›'), findsNWidgets(2));
      expect(find.byIcon(Icons.medication_outlined), findsOneWidget);
    });

    testWidgets('leading icon renders at 24px', (WidgetTester tester) async {
      await _pumpRouter(
        tester,
        _routerHosting(const PathHeader(
          breadcrumbs: _threeCrumbs,
          title: 'Medications',
          backLabel: 'Back to Medical',
          leadingIcon: Icons.medication_outlined,
        )),
      );

      final Icon icon = tester.widget<Icon>(
        find.byIcon(Icons.medication_outlined),
      );
      expect(icon.size, 24);
      expect(icon.color, careblazersColors.primary);
    });

    testWidgets('the › separator uses primarySoft',
        (WidgetTester tester) async {
      await _pumpRouter(
        tester,
        _routerHosting(const PathHeader(
          breadcrumbs: _threeCrumbs,
          title: 'Medications',
          backLabel: 'Back to Medical',
        )),
      );

      final Text separator = tester.widget<Text>(find.text('›').first);
      expect(separator.style?.color, careblazersColors.primarySoft);
    });
  });

  group('PathHeader — hub landing (single crumb)', () {
    testWidgets('renders the title only — no breadcrumb',
        (WidgetTester tester) async {
      await _pumpRouter(
        tester,
        _routerHosting(
          const PathHeader(
            breadcrumbs: <PathHeaderCrumb>[PathHeaderCrumb(label: 'Medical')],
            title: 'Medical',
          ),
          initialLocation: '/medical/medications',
        ),
      );

      expect(find.text('Medical'), findsOneWidget); // title only
      expect(find.text('›'), findsNothing);
    });
  });

  group('PathHeader — navigation', () {
    testWidgets('tapping a parent crumb routes to it',
        (WidgetTester tester) async {
      final GoRouter router = _routerHosting(const PathHeader(
        breadcrumbs: _threeCrumbs,
        title: 'Medications',
        backLabel: 'Back to Medical',
      ));
      await _pumpRouter(tester, router);
      expect(_path(router), '/medical/medications');

      await tester.tap(find.text('Medical'));
      await tester.pumpAndSettle();
      expect(_path(router), '/medical');
      expect(find.text('MEDICAL PAGE'), findsOneWidget);
    });

    testWidgets('tapping the root crumb routes home',
        (WidgetTester tester) async {
      final GoRouter router = _routerHosting(const PathHeader(
        breadcrumbs: _threeCrumbs,
        title: 'Medications',
        backLabel: 'Back to Medical',
      ));
      await _pumpRouter(tester, router);

      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(_path(router), '/');
      expect(find.text('HOME PAGE'), findsOneWidget);
    });

    testWidgets('the terminal crumb is not a tap target',
        (WidgetTester tester) async {
      final GoRouter router = _routerHosting(const PathHeader(
        breadcrumbs: _threeCrumbs,
        title: 'Medications',
        backLabel: 'Back to Medical',
      ));
      await _pumpRouter(tester, router);

      // The terminal 'Medications' crumb has no InkWell wrapper, so
      // tapping the title row text doesn't navigate.
      await tester.tap(find.text('Medications').first);
      await tester.pumpAndSettle();
      expect(_path(router), '/medical/medications');
    });
  });
}

import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/path_header.dart';
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
      expect(icon.color, holdcloseColors.primary);
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
      expect(separator.style?.color, holdcloseColors.primarySoft);
    });
  });

  group('PathHeader — tab landing (single crumb)', () {
    testWidgets('a non-Home landing gets a Home crumb prepended (Home › X)',
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

      // Every page starts from Home → "Home › Medical", not a bare title.
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('›'), findsOneWidget); // one separator: Home › Medical
      // 'Medical' is both the title and the terminal crumb.
      expect(find.text('Medical'), findsNWidgets(2));
    });

    testWidgets('the Home root suppresses the breadcrumb (just "Home")',
        (WidgetTester tester) async {
      await _pumpRouter(
        tester,
        _routerHosting(
          const PathHeader(
            breadcrumbs: <PathHeaderCrumb>[PathHeaderCrumb(label: 'Home')],
            title: 'Good morning',
          ),
          initialLocation: '/medical/medications',
        ),
      );

      expect(find.text('Good morning'), findsOneWidget); // title only
      expect(find.text('›'), findsNothing); // no self-referential crumb
    });
  });

  group('PathHeader — back button (fb_1781046567327682)', () {
    testWidgets('a sub-page shows a top-left Back that routes to the parent',
        (WidgetTester tester) async {
      final GoRouter router = _routerHosting(const PathHeader(
        breadcrumbs: _threeCrumbs, // Home › Medical › Medications
        title: 'Medications',
      ));
      await _pumpRouter(tester, router);
      expect(_path(router), '/medical/medications');

      expect(find.byKey(PathHeader.backButtonKey), findsOneWidget);
      await tester.tap(find.byKey(PathHeader.backButtonKey));
      await tester.pumpAndSettle();
      // Back goes to the parent crumb's route (/medical).
      expect(_path(router), '/medical');
    });

    testWidgets('a non-Home landing shows Back → Home',
        (WidgetTester tester) async {
      final GoRouter router = _routerHosting(const PathHeader(
        breadcrumbs: <PathHeaderCrumb>[PathHeaderCrumb(label: 'Medical')],
        title: 'Medical',
      ));
      await _pumpRouter(tester, router);

      expect(find.byKey(PathHeader.backButtonKey), findsOneWidget);
      await tester.tap(find.byKey(PathHeader.backButtonKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/'); // parent is the auto-prepended Home
    });

    testWidgets('Back pops to the pusher, not the crumb parent, when pushed',
        (WidgetTester tester) async {
      // Reproduces the Settings bug: a page reachable from many places
      // (pushed via the header gear) whose only crumb parent is Home. Back
      // must return where the user came FROM, not jump to Home.
      Widget page(String label, [Widget? body]) =>
          Scaffold(body: body ?? Center(child: Text(label)));
      final GoRouter router = GoRouter(
        initialLocation: '/elsewhere',
        routes: <RouteBase>[
          GoRoute(path: '/', builder: (_, __) => page('HOME')),
          GoRoute(path: '/elsewhere', builder: (_, __) => page('ELSEWHERE')),
          GoRoute(
            path: '/settings',
            builder: (_, __) => page(
              'SETTINGS',
              const PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Settings'),
                ],
                title: 'Settings',
              ),
            ),
          ),
        ],
      );
      await _pumpRouter(tester, router);
      expect(find.text('ELSEWHERE'), findsOneWidget);

      router.push('/settings'); // as the header gear does
      await tester.pumpAndSettle();
      // Settings is now on top; the pusher is offstage beneath it.
      expect(find.byKey(PathHeader.backButtonKey), findsOneWidget);
      expect(find.text('ELSEWHERE'), findsNothing);

      await tester.tap(find.byKey(PathHeader.backButtonKey));
      await tester.pumpAndSettle();
      // Back returned to the pusher — NOT the Home crumb.
      expect(find.text('ELSEWHERE'), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
      expect(find.byKey(PathHeader.backButtonKey), findsNothing);
    });

    testWidgets('the Home root has NO back button',
        (WidgetTester tester) async {
      await _pumpRouter(
        tester,
        _routerHosting(const PathHeader(
          breadcrumbs: <PathHeaderCrumb>[PathHeaderCrumb(label: 'Home')],
          title: 'Good morning',
        )),
      );
      expect(find.byKey(PathHeader.backButtonKey), findsNothing);
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

  group('PathHeader — a11y (breadcrumb hit target + semantics)', () {
    testWidgets('a tappable crumb is a button labelled "Back to <label>"',
        (WidgetTester tester) async {
      await _pumpRouter(
        tester,
        _routerHosting(const PathHeader(
          breadcrumbs: _threeCrumbs,
          title: 'Medications',
        )),
      );

      // The parent 'Medical' crumb announces as a button with a back label,
      // not plain text (WCAG name/role). Find the Semantics wrapper above the
      // crumb that carries the explicit "Back to <label>" name.
      final Iterable<Semantics> ancestors = tester
          .widgetList<Semantics>(find.ancestor(
            of: find.text('Medical'),
            matching: find.byType(Semantics),
          ))
          .where((Semantics s) => s.properties.label == 'Back to Medical');
      expect(ancestors, isNotEmpty);
      expect(ancestors.first.properties.button, isTrue);
    });

    testWidgets('a tappable crumb has a >=44px hit target',
        (WidgetTester tester) async {
      await _pumpRouter(
        tester,
        _routerHosting(const PathHeader(
          breadcrumbs: _threeCrumbs,
          title: 'Medications',
        )),
      );

      // The InkWell wrapping the 'Medical' crumb text is at least 44px tall.
      final Size inkSize = tester.getSize(
        find.ancestor(
          of: find.text('Medical'),
          matching: find.byType(InkWell),
        ),
      );
      expect(inkSize.height, greaterThanOrEqualTo(44));
    });
  });
}

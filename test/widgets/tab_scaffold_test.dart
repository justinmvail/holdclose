import 'package:careblazers/models/settings.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/crisis/crisis_card_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:careblazers/screens/library/library_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/tab_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Future<Widget> _pumpBar(
  WidgetTester tester, {
  required int currentIndex,
  ValueChanged<int>? onTap,
}) async {
  final Widget bar = TabScaffoldBar(
    currentIndex: currentIndex,
    onDestinationSelected: onTap ?? (_) {},
  );
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: const SizedBox.shrink(),
      bottomNavigationBar: bar,
    ),
  ));
  await tester.pumpAndSettle();
  return bar;
}

Future<GoRouter> _pumpRouter(WidgetTester tester) async {
  final GoRouter router = buildRouter();
  // ProviderScope wraps the router so the Journal branch — which now
  // watches riverpod providers — can resolve. Without it, tapping the
  // Journal tab tears down with "No ProviderScope found".
  await tester.pumpWidget(
    ProviderScope(child: MaterialApp.router(routerConfig: router)),
  );
  await tester.pumpAndSettle();
  return router;
}

String _currentPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

void main() {
  group('TabScaffoldBar — destinations', () {
    test('declares seven tabs in BUILD_SPEC.md §4.1 + Phase 12.8/13.10 order',
        () {
      // Branch order is the shell-branch declaration order; the bar
      // re-orders Community in front of Crisis via visibleBranches but
      // the destination array still follows the underlying branch
      // indices so a deep-link from a notification tap still resolves.
      expect(
        TabScaffoldBar.destinations.map((TabScaffoldDestination d) => d.label),
        <String>[
          'Home',
          'Journal',
          'Meds',
          'Visits',
          'Library',
          'Crisis',
          'Community',
        ],
      );
    });

    test('Home/Journal/Library use the calm Cupertino-style icon set', () {
      expect(TabScaffoldBar.destinations[0].icon, Icons.home_outlined);
      expect(TabScaffoldBar.destinations[0].selectedIcon, Icons.home);
      expect(TabScaffoldBar.destinations[1].icon, Icons.book_outlined);
      expect(TabScaffoldBar.destinations[1].selectedIcon, Icons.book);
      expect(TabScaffoldBar.destinations[4].icon, Icons.library_books_outlined);
      expect(TabScaffoldBar.destinations[4].selectedIcon, Icons.library_books);
    });

    test('Meds + Visits use the medication + event glyphs (Phase 12.8)', () {
      expect(TabScaffoldBar.destinations[2].icon, Icons.medication_outlined);
      expect(TabScaffoldBar.destinations[2].selectedIcon, Icons.medication);
      expect(TabScaffoldBar.destinations[3].icon, Icons.event_outlined);
      expect(TabScaffoldBar.destinations[3].selectedIcon, Icons.event);
    });

    test('Crisis uses warning_amber (calm, not the alarmist red bell)', () {
      expect(TabScaffoldBar.destinations[5].icon, Icons.warning_amber_outlined);
      expect(TabScaffoldBar.destinations[5].selectedIcon, Icons.warning_amber);
    });

    test('Community uses forum_outlined / forum (Phase 13.10)', () {
      expect(TabScaffoldBar.destinations[6].icon, Icons.forum_outlined);
      expect(TabScaffoldBar.destinations[6].selectedIcon, Icons.forum);
    });
  });

  group('TabScaffold — branch paths', () {
    test(
        'branch paths line up with BUILD_SPEC.md §4.1 + Phase 12.8/13.10 tab '
        'order',
        () {
      expect(
        TabScaffold.tabBranchPaths,
        <String>[
          '/',
          '/journal',
          '/medications',
          '/appointments',
          '/library',
          '/crisis',
          '/community',
        ],
      );
    });

    test('visibleBranchIndicesFor collapses Meds + Visits when useTrackers OFF',
        () {
      // Phase 13.10: Community sits between Library and Crisis in the
      // visible order regardless of which tracker tabs collapse.
      final AppSettings off =
          AppSettings.defaults().copyWith(useTrackers: false);
      expect(TabScaffold.visibleBranchIndicesFor(off),
          <int>[0, 1, 4, 6, 5]);
    });

    test('per-feature toggles drop matching tabs', () {
      final AppSettings noMeds =
          AppSettings.defaults().copyWith(medicationsEnabled: false);
      expect(TabScaffold.visibleBranchIndicesFor(noMeds),
          <int>[0, 1, 3, 4, 6, 5]);

      final AppSettings noAppts =
          AppSettings.defaults().copyWith(appointmentsEnabled: false);
      expect(TabScaffold.visibleBranchIndicesFor(noAppts),
          <int>[0, 1, 2, 4, 6, 5]);
    });

    test('defaults expose every tab with Community between Library and Crisis',
        () {
      expect(TabScaffold.visibleBranchIndicesFor(AppSettings.defaults()),
          <int>[0, 1, 2, 3, 4, 6, 5]);
    });
  });

  group('TabScaffoldBar — standalone widget', () {
    testWidgets('renders all seven NavigationDestinations by default',
        (WidgetTester tester) async {
      await _pumpBar(tester, currentIndex: 0);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(7));
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Journal'), findsOneWidget);
      expect(find.text('Meds'), findsOneWidget);
      expect(find.text('Visits'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Crisis'), findsOneWidget);
    });

    testWidgets('visibleBranches subset narrows the bar to chosen tabs only',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: const SizedBox.shrink(),
          bottomNavigationBar: TabScaffoldBar(
            currentIndex: 0,
            visibleBranches: const <int>[0, 1, 4, 5],
            onDestinationSelected: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDestination), findsNWidgets(4));
      expect(find.text('Meds'), findsNothing);
      expect(find.text('Visits'), findsNothing);
      expect(find.text('Community'), findsNothing);
    });

    testWidgets('forwards taps to onDestinationSelected',
        (WidgetTester tester) async {
      // Default visibleBranches put Community (visual slot 5) between
      // Library (4) and Crisis (visual slot 6) — the bar callback
      // reports the *visual* slot index, not the underlying branch.
      int? tapped;
      await _pumpBar(
        tester,
        currentIndex: 0,
        onTap: (int index) => tapped = index,
      );

      await tester.tap(find.byIcon(Icons.warning_amber_outlined));
      expect(tapped, 6);

      await tester.tap(find.byIcon(Icons.forum_outlined));
      expect(tapped, 5);

      await tester.tap(find.byIcon(Icons.book_outlined));
      expect(tapped, 1);
    });

    testWidgets(
      'NavigationBarTheme paints active=primary / inactive=primarySoft',
      (WidgetTester tester) async {
        await _pumpBar(tester, currentIndex: 1);

        final BuildContext barContext =
            tester.element(find.byType(NavigationBar));
        final NavigationBarThemeData themeData =
            NavigationBarTheme.of(barContext);

        final IconThemeData selectedIcon = themeData.iconTheme!
            .resolve(<WidgetState>{WidgetState.selected})!;
        final IconThemeData unselectedIcon =
            themeData.iconTheme!.resolve(<WidgetState>{})!;
        expect(selectedIcon.color, careblazersColors.primary);
        expect(unselectedIcon.color, careblazersColors.primarySoft);

        final TextStyle selectedLabel = themeData.labelTextStyle!
            .resolve(<WidgetState>{WidgetState.selected})!;
        final TextStyle unselectedLabel =
            themeData.labelTextStyle!.resolve(<WidgetState>{})!;
        expect(selectedLabel.color, careblazersColors.primary);
        expect(unselectedLabel.color, careblazersColors.primarySoft);
      },
    );

    testWidgets(
      'currentIndex highlights the matching destination',
      (WidgetTester tester) async {
        await _pumpBar(tester, currentIndex: 2);
        expect(
          tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          2,
        );
      },
    );
  });

  group('TabScaffold — wired via go_router StatefulShellRoute', () {
    testWidgets(
      'tapping each tab switches the shell branch',
      (WidgetTester tester) async {
        final GoRouter router = await _pumpRouter(tester);

        expect(find.byType(TabScaffold), findsOneWidget);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(_currentPath(router), '/');

        await tester.tap(find.byIcon(Icons.book_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/journal');
        expect(find.byType(JournalScreen), findsOneWidget);

        await tester.tap(find.byIcon(Icons.library_books_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/library');
        expect(find.byType(LibraryScreen), findsOneWidget);

        await tester.tap(find.byIcon(Icons.warning_amber_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/crisis');
        expect(find.byType(CrisisCardScreen), findsOneWidget);

        // Now on Crisis, the Home icon is the outlined (inactive) glyph.
        await tester.tap(find.byIcon(Icons.home_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
      },
    );
  });
}

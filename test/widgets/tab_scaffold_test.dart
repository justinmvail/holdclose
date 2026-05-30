import 'package:careblazers/models/chat.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/home_conversation_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/tab_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

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
  final DateTime now = DateTime.utc(2026, 5, 30, 12);
  // ProviderScope wraps the router so the Journal branch — which now
  // watches riverpod providers — can resolve. Without it, tapping the
  // Journal tab tears down with "No ProviderScope found".
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        homeConversationProvider.overrideWith(
          (_) async => Conversation(
            id: 'tab-test-conv',
            title: 'Today',
            createdAt: now,
            updatedAt: now,
          ),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _currentPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

void main() {
  group('TabScaffoldBar — destinations', () {
    test('declares five tabs (post home-refactor — no Crisis in the bar)',
        () {
      expect(
        TabScaffoldBar.destinations.map((TabScaffoldDestination d) => d.label),
        <String>[
          'Home',
          'Journal',
          'Meds',
          'Visits',
          'Community',
        ],
      );
    });

    test('Home + Journal use the calm Cupertino-style icon set', () {
      expect(TabScaffoldBar.destinations[0].icon, Icons.home_outlined);
      expect(TabScaffoldBar.destinations[0].selectedIcon, Icons.home);
      expect(TabScaffoldBar.destinations[1].icon, Icons.book_outlined);
      expect(TabScaffoldBar.destinations[1].selectedIcon, Icons.book);
    });

    test('Meds + Visits use the medication + event glyphs (Phase 12.8)', () {
      expect(TabScaffoldBar.destinations[2].icon, Icons.medication_outlined);
      expect(TabScaffoldBar.destinations[2].selectedIcon, Icons.medication);
      expect(TabScaffoldBar.destinations[3].icon, Icons.event_outlined);
      expect(TabScaffoldBar.destinations[3].selectedIcon, Icons.event);
    });

    test('Community uses forum_outlined / forum (Phase 13.10)', () {
      expect(TabScaffoldBar.destinations[4].icon, Icons.forum_outlined);
      expect(TabScaffoldBar.destinations[4].selectedIcon, Icons.forum);
    });
  });

  group('TabScaffold — branch paths', () {
    test(
        'branch paths line up with the post-home-refactor tab order',
        () {
      expect(
        TabScaffold.tabBranchPaths,
        <String>[
          '/',
          '/journal',
          '/medications',
          '/appointments',
          '/community',
        ],
      );
    });

    test('visibleBranchIndicesFor collapses Meds + Visits when useTrackers OFF',
        () {
      final AppSettings off =
          AppSettings.defaults().copyWith(useTrackers: false);
      expect(TabScaffold.visibleBranchIndicesFor(off),
          <int>[0, 1, 4]);
    });

    test('per-feature toggles drop matching tabs', () {
      final AppSettings noMeds =
          AppSettings.defaults().copyWith(medicationsEnabled: false);
      expect(TabScaffold.visibleBranchIndicesFor(noMeds),
          <int>[0, 1, 3, 4]);

      final AppSettings noAppts =
          AppSettings.defaults().copyWith(appointmentsEnabled: false);
      expect(TabScaffold.visibleBranchIndicesFor(noAppts),
          <int>[0, 1, 2, 4]);
    });

    test('defaults expose every tab in shell-branch order',
        () {
      expect(TabScaffold.visibleBranchIndicesFor(AppSettings.defaults()),
          <int>[0, 1, 2, 3, 4]);
    });
  });

  group('TabScaffoldBar — standalone widget', () {
    testWidgets('renders all five NavigationDestinations by default',
        (WidgetTester tester) async {
      await _pumpBar(tester, currentIndex: 0);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(5));
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Journal'), findsOneWidget);
      expect(find.text('Meds'), findsOneWidget);
      expect(find.text('Visits'), findsOneWidget);
      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Crisis'), findsNothing);
    });

    testWidgets('visibleBranches subset narrows the bar to chosen tabs only',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: const SizedBox.shrink(),
          bottomNavigationBar: TabScaffoldBar(
            currentIndex: 0,
            visibleBranches: const <int>[0, 1],
            onDestinationSelected: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDestination), findsNWidgets(2));
      expect(find.text('Meds'), findsNothing);
      expect(find.text('Visits'), findsNothing);
      expect(find.text('Community'), findsNothing);
    });

    testWidgets('forwards taps to onDestinationSelected',
        (WidgetTester tester) async {
      // Visible bar order: [Home, Journal, Meds, Visits, Community]
      // → visual slots 0..4. The callback fires the *visual* slot,
      // not the underlying branch index.
      int? tapped;
      await _pumpBar(
        tester,
        currentIndex: 0,
        onTap: (int index) => tapped = index,
      );

      await tester.tap(find.byIcon(Icons.forum_outlined));
      expect(tapped, 4);

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

        await tester.tap(find.byIcon(Icons.home_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
      },
    );
  });
}

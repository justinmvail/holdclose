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
    test('declares four tabs in BUILD_SPEC.md §4.1 order', () {
      expect(
        TabScaffoldBar.destinations.map((TabScaffoldDestination d) => d.label),
        <String>['Home', 'Journal', 'Library', 'Crisis'],
      );
    });

    test('Home/Journal/Library use the calm Cupertino-style icon set', () {
      expect(TabScaffoldBar.destinations[0].icon, Icons.home_outlined);
      expect(TabScaffoldBar.destinations[0].selectedIcon, Icons.home);
      expect(TabScaffoldBar.destinations[1].icon, Icons.book_outlined);
      expect(TabScaffoldBar.destinations[1].selectedIcon, Icons.book);
      expect(TabScaffoldBar.destinations[2].icon, Icons.library_books_outlined);
      expect(TabScaffoldBar.destinations[2].selectedIcon, Icons.library_books);
    });

    test('Crisis uses warning_amber (calm, not the alarmist red bell)', () {
      expect(TabScaffoldBar.destinations[3].icon, Icons.warning_amber_outlined);
      expect(TabScaffoldBar.destinations[3].selectedIcon, Icons.warning_amber);
    });
  });

  group('TabScaffold — branch paths', () {
    test('branch paths line up with BUILD_SPEC.md §4.1 tab order', () {
      expect(
        TabScaffold.tabBranchPaths,
        <String>['/', '/journal', '/library', '/crisis'],
      );
    });
  });

  group('TabScaffoldBar — standalone widget', () {
    testWidgets('renders all four NavigationDestinations',
        (WidgetTester tester) async {
      await _pumpBar(tester, currentIndex: 0);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(4));
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Journal'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Crisis'), findsOneWidget);
    });

    testWidgets('forwards taps to onDestinationSelected',
        (WidgetTester tester) async {
      int? tapped;
      await _pumpBar(
        tester,
        currentIndex: 0,
        onTap: (int index) => tapped = index,
      );

      await tester.tap(find.byIcon(Icons.warning_amber_outlined));
      expect(tapped, 3);

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

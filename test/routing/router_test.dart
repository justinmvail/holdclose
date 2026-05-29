import 'dart:async';

import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/crisis/crisis_card_screen.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:careblazers/screens/library/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Pump the router wrapped in a bare MaterialApp. We deliberately
/// skip `careblazersLightTheme` here — its google_fonts TextStyles
/// fire fire-and-forget Futures during construction; in unit tests
/// without bundled font assets those Futures fail in the root zone
/// and surface as uncaught errors. The theme contract is owned by
/// theme_test.dart; here we only care about route registration.
Future<GoRouter> pumpRouter(
  WidgetTester tester, {
  String initialLocation = '/',
}) async {
  final GoRouter router = buildRouter(initialLocation: initialLocation);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

String currentPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

void main() {
  group('careblazersRouter — BUILD_SPEC.md §5 registration', () {
    // Every path BUILD_SPEC.md §5 names. Dynamic-segment routes are
    // probed with a sample id so we exercise the parameterised path.
    const Map<String, String> sectionPaths = <String, String>{
      '§5.1 Home': '/',
      '§5.2 Behavior picker': '/decoder/behavior',
      '§5.3 Triage': '/decoder/triage',
      '§5.4 Decoder result': '/decoder/result',
      '§5.5 Journal': '/journal',
      '§5.6 Journal entry detail': '/journal/sample-id',
      '§5.7 Library': '/library',
      '§5.8 Library card detail': '/library/anosognosia',
      '§5.9 Crisis card': '/crisis',
      '§5.10 Settings': '/settings',
      '§5.11 Welcome carousel': '/onboarding',
      '§5.12 Sign-in': '/sign-in',
    };

    sectionPaths.forEach((String section, String path) {
      testWidgets('$section registered at $path', (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);
        router.go(path);
        await tester.pumpAndSettle();

        expect(
          currentPath(router),
          path,
          reason: '$section ($path) did not register; router stayed at '
              '${currentPath(router)}',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$section ($path) threw on navigation',
        );
      });
    });
  });

  group('careblazersRouter — tab shell', () {
    testWidgets(
      'opens on Home (§5.1) by default with the four-tab NavigationBar',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        expect(currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsOneWidget);
        // Tab labels appear in the exact §4.1 order.
        expect(find.text('Home'), findsOneWidget);
        expect(find.text('Journal'), findsOneWidget);
        expect(find.text('Library'), findsOneWidget);
        expect(find.text('Crisis'), findsOneWidget);
      },
    );

    testWidgets(
      'tab-bar tap switches branches via context.go',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        await tester.tap(find.byIcon(Icons.menu_book_outlined));
        await tester.pumpAndSettle();
        expect(currentPath(router), '/journal');
        expect(find.byType(JournalScreen), findsOneWidget);

        await tester.tap(find.byIcon(Icons.local_library_outlined));
        await tester.pumpAndSettle();
        expect(currentPath(router), '/library');
        expect(find.byType(LibraryScreen), findsOneWidget);

        await tester.tap(find.byIcon(Icons.warning_amber_outlined));
        await tester.pumpAndSettle();
        expect(currentPath(router), '/crisis');
        expect(find.byType(CrisisCardScreen), findsOneWidget);

        // Selected icon is `home` (filled variant) once we land back
        // on the Home branch; we tap the outlined Journal icon first
        // to leave Home, then return via the now-outlined Home icon.
        await tester.tap(find.byIcon(Icons.home_outlined));
        await tester.pumpAndSettle();
        expect(currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
      },
    );
  });

  group('careblazersRouter — push from Home', () {
    testWidgets(
      'Home → /decoder/behavior via context.push leaves a back arrow',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        // Root of the Home tab has no back arrow.
        expect(find.byType(BackButton), findsNothing);

        // `push` returns a Future that completes only when the route
        // is popped — we'll pop it ourselves below, so don't await.
        // Note: `push` adds an imperative match on top of the current
        // RouteMatchList. go_router doesn't roll the displayed URL
        // forward for imperative pushes (the URL still reads `/`),
        // so we assert navigation by what the user actually sees:
        // the BehaviorPickerScreen and the auto-rendered back arrow.
        unawaited(router.push('/decoder/behavior'));
        await tester.pumpAndSettle();

        expect(find.byType(BehaviorPickerScreen), findsOneWidget);
        expect(
          find.byType(BackButton),
          findsOneWidget,
          reason: 'pushed routes must auto-render a back arrow',
        );
        // The pushed route covers the tab shell.
        expect(find.byType(NavigationBar), findsNothing);

        // Tapping the back arrow pops the push and returns to Home.
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byType(BehaviorPickerScreen), findsNothing);
        expect(currentPath(router), '/');
      },
    );
  });
}

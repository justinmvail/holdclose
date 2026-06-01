import 'dart:async';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/providers/home_conversation_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/chat/conversation_list_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/tab_scaffold.dart';
import 'package:drift/native.dart';
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
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = buildRouter();
  final DateTime now = DateTime.utc(2026, 5, 30, 12);
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  // ProviderScope wraps the router so the branches that watch riverpod
  // providers (Home → homeConversationProvider, Chat →
  // chatRepositoryProvider) can resolve. Without it, switching to those
  // tabs tears down with "No ProviderScope found".
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
        chatRepositoryProvider.overrideWith((_) => ChatRepository(db)),
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
    test('declares the fixed five tabs (Phase 14 IA)', () {
      expect(
        TabScaffoldBar.destinations.map((TabScaffoldDestination d) => d.label),
        <String>[
          'Home',
          'Medical',
          'Team',
          'Chat',
          'Community',
        ],
      );
    });

    test('Home + Medical use the calm Cupertino-style icon set', () {
      expect(TabScaffoldBar.destinations[0].icon, Icons.home_outlined);
      expect(TabScaffoldBar.destinations[0].selectedIcon, Icons.home);
      expect(
        TabScaffoldBar.destinations[1].icon,
        Icons.local_hospital_outlined,
      );
      expect(TabScaffoldBar.destinations[1].selectedIcon, Icons.local_hospital);
    });

    test('Team + Chat use the diversity + chat glyphs', () {
      expect(TabScaffoldBar.destinations[2].icon, Icons.diversity_3_outlined);
      expect(TabScaffoldBar.destinations[2].selectedIcon, Icons.diversity_3);
      expect(TabScaffoldBar.destinations[3].icon, Icons.chat_bubble_outline);
      expect(TabScaffoldBar.destinations[3].selectedIcon, Icons.chat_bubble);
    });

    test('Community keeps forum_outlined / forum', () {
      expect(TabScaffoldBar.destinations[4].icon, Icons.forum_outlined);
      expect(TabScaffoldBar.destinations[4].selectedIcon, Icons.forum);
    });
  });

  group('TabScaffold — branch paths', () {
    test('branch paths line up with the fixed five-tab order', () {
      expect(
        TabScaffold.tabBranchPaths,
        <String>[
          '/',
          '/medical',
          '/team',
          '/chat',
          '/community',
        ],
      );
    });

    test('there are exactly as many branch paths as destinations', () {
      expect(
        TabScaffold.tabBranchPaths.length,
        TabScaffoldBar.destinations.length,
      );
    });
  });

  group('TabScaffoldBar — standalone widget', () {
    testWidgets('always renders all five NavigationDestinations',
        (WidgetTester tester) async {
      await _pumpBar(tester, currentIndex: 0);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(5));
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Medical'), findsOneWidget);
      expect(find.text('Team'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Community'), findsOneWidget);
    });

    testWidgets('forwards taps to onDestinationSelected by slot index',
        (WidgetTester tester) async {
      // Bar order: [Home, Medical, Team, Chat, Community] → slots 0..4.
      // With the fixed bar, the slot index IS the branch index.
      int? tapped;
      await _pumpBar(
        tester,
        currentIndex: 0,
        onTap: (int index) => tapped = index,
      );

      await tester.tap(find.byIcon(Icons.forum_outlined));
      expect(tapped, 4);

      await tester.tap(find.byIcon(Icons.local_hospital_outlined));
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

        // Medical — the tile hub (Phase 14.15).
        await tester.tap(find.byIcon(Icons.local_hospital_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/medical');
        expect(find.byType(MedicalHubScreen), findsOneWidget);

        // Team — placeholder hub until Phase 14.26.
        await tester.tap(find.byIcon(Icons.diversity_3_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/team');
        expect(find.widgetWithText(AppBar, 'Care Team'), findsOneWidget);

        // Chat — direct landing.
        await tester.tap(find.byIcon(Icons.chat_bubble_outline));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/chat');
        expect(find.byType(ConversationListScreen), findsOneWidget);

        // Community — direct landing.
        await tester.tap(find.byIcon(Icons.forum_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/community');

        // Back to Home.
        await tester.tap(find.byIcon(Icons.home_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
      },
    );

    testWidgets(
      're-tapping the active tab pops its branch back to the hub',
      (WidgetTester tester) async {
        final GoRouter router = await _pumpRouter(tester);

        // Land on the Chat branch and push a thread onto its navigator.
        router.go('/chat');
        await tester.pumpAndSettle();
        expect(find.byType(ConversationListScreen), findsOneWidget);

        unawaited(router.push('/chat/sample-id'));
        await tester.pumpAndSettle();
        expect(find.byType(ConversationListScreen), findsNothing);

        // Re-tap the (now active) Chat tab — its filled glyph is showing.
        await tester.tap(find.byIcon(Icons.chat_bubble));
        await tester.pumpAndSettle();

        expect(
          find.byType(ConversationListScreen),
          findsOneWidget,
          reason: 're-tapping the active tab resets the branch to its hub',
        );
      },
    );
  });
}

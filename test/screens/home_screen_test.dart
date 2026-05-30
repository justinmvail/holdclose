import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/providers/home_conversation_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/chat/chat_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

Conversation _stubConversation() => Conversation(
      id: 'home-conv-stub',
      title: 'Today',
      createdAt: _fixedNow,
      updatedAt: _fixedNow,
    );

Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  Conversation? conversation,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final Conversation conv = conversation ?? _stubConversation();
  final CareblazersDatabase db =
      CareblazersDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final GoRouter router = buildRouter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        homeConversationProvider.overrideWith((_) async => conv),
        chatRepositoryProvider.overrideWith((_) => ChatRepository(db)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('HomeScreen — chat-shaped tab root (home refactor)', () {
    testWidgets('AppBar title is "Today" with the three actions',
        (WidgetTester tester) async {
      await _pumpHome(tester);

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Today'), findsOneWidget);
      expect(find.byKey(HomeScreen.historyButtonKey), findsOneWidget);
      expect(find.byKey(HomeScreen.newConversationKey), findsOneWidget);
      expect(find.byKey(HomeScreen.settingsGearKey), findsOneWidget);
    });

    testWidgets('renders a ChatScreen against the resolved conversation',
        (WidgetTester tester) async {
      await _pumpHome(tester);

      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('"Log a journal entry" quick action wires to the wizard',
        (WidgetTester tester) async {
      await _pumpHome(tester);

      final Finder action = find.byKey(HomeScreen.journalQuickActionKey);
      expect(action, findsOneWidget);

      // Just assert the action exists + its first descendant InkWell
      // has an onTap closure. Driving the closure through GoRouter
      // navigation is covered end-to-end by the router_test suite for
      // the `/journal/new` registration; pumping a live nav here would
      // need a real drift store (the wizard screen's submit path reads
      // it on mount).
      final InkWell well = tester
          .widgetList<InkWell>(
              find.descendant(of: action, matching: find.byType(InkWell)))
          .first;
      expect(well.onTap, isNotNull);
    });

    testWidgets('settings gear wires onPressed (closure attached)',
        (WidgetTester tester) async {
      await _pumpHome(tester);
      final IconButton gear = tester
          .widget<IconButton>(find.byKey(HomeScreen.settingsGearKey));
      expect(gear.onPressed, isNotNull);
    });

    testWidgets('settings gear carries a Settings tooltip',
        (WidgetTester tester) async {
      await _pumpHome(tester);
      // Tooltip is what IconButton wires into the semantics tree via
      // `tooltip:` — assert it's the canonical "Settings" wording the
      // gear has carried since BUILD_SPEC.md §5.1.
      final IconButton gear = tester
          .widget<IconButton>(find.byKey(HomeScreen.settingsGearKey));
      expect(gear.tooltip, 'Settings');
    });
  });
}

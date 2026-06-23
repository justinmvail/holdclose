import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/routing/router.dart';
import 'package:holdclose/screens/chat/chat_screen.dart';
import 'package:holdclose/screens/chat/conversation_list_screen.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/widgets/tab_scaffold.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime.utc(2026, 5, 29, 19, 42);

/// Pumps the real tab shell (`buildRouter`) at the Chat branch so these
/// tests exercise the genuine `StatefulShellRoute` + [TabScaffold] wiring
/// the Chat tab uses in production (Phase 14.34) — not a stand-in router.
///
/// Only the Chat branch is preloaded (branches default to lazy build), so
/// the other four tabs' screens never mount and we don't drag their
/// providers into the harness.
Future<({ChatRepository repo, HoldcloseDatabase db})> _pump(
  WidgetTester tester, {
  required ChatRepository repo,
  required HoldcloseDatabase db,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        chatRepositoryBackendProvider.overrideWithValue(repo),
        conversationListClockProvider.overrideWithValue(_fixedNow),
        conversationListIdFactoryProvider.overrideWithValue(() => 'convo-new'),
      ],
      child: MaterialApp.router(
        routerConfig: buildRouter(initialLocation: '/chat'),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return (repo: repo, db: db);
}

/// Seed one conversation with a user turn so the list shows a tappable
/// tile and the opened thread carries a derived name.
Future<void> _seedOneThread(ChatRepository repo) async {
  await repo.createConversation(
    id: 'convo-1',
    title: 'placeholder',
    createdAt: _fixedNow(),
  );
  await repo.appendMessage(Message(
    id: 'msg-1',
    conversationId: 'convo-1',
    role: MessageRole.user,
    body: 'When she asks to go home, what do I say?',
    citations: const <String>[],
    createdAt: _fixedNow(),
    streamingDone: true,
  ));
}

void main() {
  late HoldcloseDatabase db;
  late ChatRepository repo;

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
    repo = ChatRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('Chat tab — thread navigation (TASKS.md Phase 14.34)', () {
    testWidgets('re-tapping the Chat tab while on a thread pops to the list',
        (WidgetTester tester) async {
      await _seedOneThread(repo);
      await _pump(tester, repo: repo, db: db);

      // Open the thread from the list.
      await tester.tap(find.byKey(ConversationListScreen.tileKey('convo-1')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(ConversationListScreen), findsNothing);

      // Re-tap the (already-active) Chat tab in the bottom bar — the
      // iOS-style "tap the active tab to pop to root" affordance resets
      // the Chat branch back to the conversation list.
      await tester.tap(
        find.descendant(
          of: find.byType(TabScaffoldBar),
          matching: find.text('Chat'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ConversationListScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
    });

    testWidgets(
        'navigating thread→thread shows the NEW thread\'s messages '
        '(fb_1781035154885086)', (WidgetTester tester) async {
      // Two distinct threads, each with its own message.
      await repo.createConversation(
          id: 'convo-A', title: 'A', createdAt: _fixedNow());
      await repo.appendMessage(Message(
        id: 'a1',
        conversationId: 'convo-A',
        role: MessageRole.user,
        body: 'message in thread A',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      ));
      await repo.createConversation(
          id: 'convo-B', title: 'B', createdAt: _fixedNow());
      await repo.appendMessage(Message(
        id: 'b1',
        conversationId: 'convo-B',
        role: MessageRole.user,
        body: 'message in thread B',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      ));

      await _pump(tester, repo: repo, db: db);
      final GoRouter router =
          GoRouter.of(tester.element(find.byType(ConversationListScreen)));

      router.go('/chat/convo-A');
      await tester.pumpAndSettle();
      // Present (the body shows in the bubble + the derived title/crumb).
      expect(find.text('message in thread A'), findsWidgets);

      // Jump straight to thread B (what the center mic does when it opens a
      // fresh thread while one is already open). Before the route was keyed
      // by id, the ChatScreen was reused and kept showing thread A.
      router.go('/chat/convo-B');
      await tester.pumpAndSettle();
      expect(find.text('message in thread B'), findsWidgets);
      // The smoking gun: thread A's content is GONE — the screen reloaded.
      expect(find.text('message in thread A'), findsNothing);
    });

    testWidgets("the thread's PathHeader parent crumb returns to the list",
        (WidgetTester tester) async {
      await _seedOneThread(repo);
      await _pump(tester, repo: repo, db: db);

      await tester.tap(find.byKey(ConversationListScreen.tileKey('convo-1')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);

      // The thread header's parent breadcrumb crumb ('Chat') is the back
      // affordance now (the separate "Back to Chat" control was removed as
      // redundant). Tapping it runs `context.go('/chat')`, popping the
      // pushed thread off the Chat branch navigator back to the list.
      await tester.tap(find.widgetWithText(InkWell, 'Chat'));
      await tester.pumpAndSettle();

      expect(find.byType(ConversationListScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
    });
  });
}

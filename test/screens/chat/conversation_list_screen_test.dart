import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/screens/chat/chat_screen.dart';
import 'package:careblazers/screens/chat/conversation_list_screen.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../_semantics_matchers.dart';

DateTime _fixedNow() => DateTime.utc(2026, 5, 29, 19, 42);

/// Pump [ConversationListScreen] inside a minimal router so push events
/// land somewhere the test can observe.
Future<({
  ChatRepository repo,
  GoRouter router,
  List<String> pushedPaths,
  CareblazersDatabase db,
})> _pump(
  WidgetTester tester, {
  required ChatRepository repo,
  required CareblazersDatabase db,
  String idOverride = 'convo-new-1',
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> pushedPaths = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/chat',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/chat',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const ConversationListScreen(),
      ),
      GoRoute(
        path: '/chat/:id',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) {
          pushedPaths.add('/chat/${state.pathParameters['id']}');
          return const Scaffold(
            body: Center(child: Text('test-thread')),
          );
        },
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        chatRepositoryBackendProvider.overrideWithValue(repo),
        conversationListClockProvider.overrideWithValue(_fixedNow),
        conversationListIdFactoryProvider.overrideWithValue(() => idOverride),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  return (repo: repo, router: router, pushedPaths: pushedPaths, db: db);
}

void main() {
  late CareblazersDatabase db;
  late ChatRepository repo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = ChatRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('ConversationListScreen — TASKS.md Phase 11.4 empty state', () {
    testWidgets('renders the empty state with a Quick Chat CTA when no '
        'conversations exist', (WidgetTester tester) async {
      await _pump(tester, repo: repo, db: db);

      expect(find.byKey(ConversationListScreen.emptyStateKey), findsOneWidget);
      expect(
        find.byKey(ConversationListScreen.emptyQuickChatKey),
        findsOneWidget,
      );
      // No FAB while empty — the inline CTA replaces it.
      expect(find.byKey(ConversationListScreen.fabQuickChatKey), findsNothing);
    });

    testWidgets('tapping the empty-state Quick Chat creates a conversation '
        'and pushes /chat/<id>', (WidgetTester tester) async {
      final ({
        ChatRepository repo,
        GoRouter router,
        List<String> pushedPaths,
        CareblazersDatabase db,
      }) p = await _pump(
        tester,
        repo: repo,
        db: db,
        idOverride: 'convo-fresh',
      );

      await tester.tap(find.byKey(ConversationListScreen.emptyQuickChatKey));
      await tester.pumpAndSettle();

      expect(p.pushedPaths, <String>['/chat/convo-fresh']);
      final List<Conversation> rows = await p.repo.listConversations();
      expect(rows.map((Conversation c) => c.id).toList(),
          <String>['convo-fresh']);
      expect(rows.single.createdAt, _fixedNow());
    });
  });

  group('ConversationListScreen — TASKS.md Phase 11.4 populated state', () {
    testWidgets('renders one tile per conversation, freshest first', (
      WidgetTester tester,
    ) async {
      final DateTime base = _fixedNow();
      await repo.createConversation(
        id: 'convo-old',
        title: 'placeholder',
        createdAt: base.subtract(const Duration(hours: 2)),
      );
      await repo.appendMessage(Message(
        id: 'msg-old-1',
        conversationId: 'convo-old',
        role: MessageRole.user,
        body: 'What is sundowning and why does she get so agitated at dusk?',
        citations: const <String>[],
        createdAt: base.subtract(const Duration(hours: 2)),
        streamingDone: true,
      ));
      await repo.appendMessage(Message(
        id: 'msg-old-2',
        conversationId: 'convo-old',
        role: MessageRole.assistant,
        body: 'The brain in transition causes the late-day agitation.',
        citations: const <String>[],
        createdAt: base.subtract(const Duration(hours: 2))
            .add(const Duration(minutes: 1)),
        streamingDone: true,
      ));
      await repo.createConversation(
        id: 'convo-new',
        title: 'placeholder',
        createdAt: base,
      );
      await repo.appendMessage(Message(
        id: 'msg-new-1',
        conversationId: 'convo-new',
        role: MessageRole.user,
        body: 'When she says she wants to go home, what do I say?',
        citations: const <String>[],
        createdAt: base,
        streamingDone: true,
      ));
      await repo.appendMessage(Message(
        id: 'msg-new-2',
        conversationId: 'convo-new',
        role: MessageRole.assistant,
        body: 'Step into her reality and validate the feeling.',
        citations: const <String>[],
        createdAt: base.add(const Duration(minutes: 1)),
        streamingDone: true,
      ));

      await _pump(tester, repo: repo, db: db);

      expect(find.byKey(ConversationListScreen.listKey), findsOneWidget);
      expect(
        find.byKey(ConversationListScreen.tileKey('convo-old')),
        findsOneWidget,
      );
      expect(
        find.byKey(ConversationListScreen.tileKey('convo-new')),
        findsOneWidget,
      );

      // Tile titles derive from the first user message's first 60 chars.
      // The "new" message is under 60 chars and renders verbatim.
      expect(
        find.descendant(
          of: find.byKey(ConversationListScreen.tileKey('convo-new')),
          matching: find.text(
            'When she says she wants to go home, what do I say?',
          ),
        ),
        findsOneWidget,
      );
      // The "old" title runs over 60 chars and gets the ellipsis suffix.
      const String oldExpected =
          'What is sundowning and why does she get so agitated at dusk?';
      expect(
        find.descendant(
          of: find.byKey(ConversationListScreen.tileKey('convo-old')),
          matching: find.text(oldExpected.length <= 60
              ? oldExpected
              : '${oldExpected.substring(0, 60)}…'),
        ),
        findsOneWidget,
      );

      // Freshest first — convo-new tile sits above convo-old tile.
      final double yNew = tester
          .getTopLeft(find.byKey(ConversationListScreen.tileKey('convo-new')))
          .dy;
      final double yOld = tester
          .getTopLeft(find.byKey(ConversationListScreen.tileKey('convo-old')))
          .dy;
      expect(yNew, lessThan(yOld));
    });

    testWidgets('a conversation with no user messages displays the '
        '"New chat" fallback', (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-empty',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );

      await _pump(tester, repo: repo, db: db);

      expect(find.text('New chat'), findsOneWidget);
    });

    testWidgets('FAB is visible when the list is populated', (
      WidgetTester tester,
    ) async {
      await repo.createConversation(
        id: 'convo-x',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );

      await _pump(tester, repo: repo, db: db);

      expect(find.byKey(ConversationListScreen.fabQuickChatKey), findsOneWidget);
      // Empty-state inline CTA is replaced by the FAB.
      expect(
        find.byKey(ConversationListScreen.emptyQuickChatKey),
        findsNothing,
      );
    });

    testWidgets('tapping a tile pushes /chat/<conversation id>', (
      WidgetTester tester,
    ) async {
      await repo.createConversation(
        id: 'convo-tap',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );

      final ({
        ChatRepository repo,
        GoRouter router,
        List<String> pushedPaths,
        CareblazersDatabase db,
      }) p = await _pump(tester, repo: repo, db: db);

      await tester.tap(find.byKey(ConversationListScreen.tileKey('convo-tap')));
      await tester.pumpAndSettle();

      expect(p.pushedPaths, <String>['/chat/convo-tap']);
    });

    testWidgets('tapping the FAB creates a new conversation and pushes '
        '/chat/<new-id>', (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-existing',
        title: 'placeholder',
        createdAt: _fixedNow().subtract(const Duration(hours: 1)),
      );

      final ({
        ChatRepository repo,
        GoRouter router,
        List<String> pushedPaths,
        CareblazersDatabase db,
      }) p = await _pump(
        tester,
        repo: repo,
        db: db,
        idOverride: 'convo-fab',
      );

      await tester.tap(find.byKey(ConversationListScreen.fabQuickChatKey));
      await tester.pumpAndSettle();

      expect(p.pushedPaths, <String>['/chat/convo-fab']);
      final List<Conversation> rows = await p.repo.listConversations();
      // Freshly-created conversation appears in the list and is the
      // freshest row (updatedAt > the pre-existing one).
      expect(rows.first.id, 'convo-fab');
      expect(rows.length, 2);
    });
  });

  group('ConversationListScreen — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets('the empty-state Quick Chat button has a screen-reader label',
        (WidgetTester tester) async {
      await _pump(tester, repo: repo, db: db);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Quick chat.*Start a new conversation with the coach'),
        ),
        isTrue,
      );
    });

    testWidgets('every populated tile announces its title', (
      WidgetTester tester,
    ) async {
      await repo.createConversation(
        id: 'convo-a',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );
      await repo.appendMessage(Message(
        id: 'msg-a-1',
        conversationId: 'convo-a',
        role: MessageRole.user,
        body: 'How do I respond when he asks for his mother?',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      ));

      await _pump(tester, repo: repo, db: db);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp(
            '${RegExp.escape("How do I respond when he asks for his mother?")}.*'
            'Double-tap to open this chat',
          ),
        ),
        isTrue,
      );
    });
  });

  group('ConversationListScreen — title derivation', () {
    test('ConversationListItem.displayTitle returns first 60 chars + ellipsis '
        'when the message is long', () {
      const String body =
          'What do I do when sundowning hits and nothing else seems to work for her?';
      final ConversationListItem item = ConversationListItem(
        conversation: Conversation(
          id: 'x',
          title: 'placeholder',
          createdAt: _fixedNow(),
          updatedAt: _fixedNow(),
        ),
        firstUserMessage: body,
        lastMessage: body,
      );

      expect(item.displayTitle, '${body.substring(0, 60)}…');
    });

    test('ConversationListItem.displayTitle returns the body verbatim when '
        'shorter than 60 chars', () {
      const String body = 'short question';
      final ConversationListItem item = ConversationListItem(
        conversation: Conversation(
          id: 'x',
          title: 'placeholder',
          createdAt: _fixedNow(),
          updatedAt: _fixedNow(),
        ),
        firstUserMessage: body,
        lastMessage: body,
      );

      expect(item.displayTitle, 'short question');
    });

    test('ConversationListItem.displayTitle falls back to "New chat" when no '
        'user message is on the thread yet', () {
      final ConversationListItem item = ConversationListItem(
        conversation: Conversation(
          id: 'x',
          title: 'placeholder',
          createdAt: _fixedNow(),
          updatedAt: _fixedNow(),
        ),
        firstUserMessage: null,
        lastMessage: null,
      );

      expect(item.displayTitle, 'New chat');
    });
  });

  group('ChatScreen route registration sanity', () {
    testWidgets('a freshly-pushed /chat/<id> mounts ChatScreen without '
        'exception', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await repo.createConversation(
        id: 'convo-route',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );

      final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
      final GoRouter router = GoRouter(
        initialLocation: '/chat/convo-route',
        navigatorKey: rootKey,
        routes: <RouteBase>[
          GoRoute(
            path: '/chat/:id',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) => ChatScreen(
              conversationId: state.pathParameters['id'] ?? '',
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            chatRepositoryBackendProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(
            theme: ThemeData(
              scaffoldBackgroundColor: careblazersColors.background,
            ),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ChatScreen), findsOneWidget);
    });
  });
}

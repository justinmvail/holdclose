import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/screens/chat/chat_screen.dart';
import 'package:holdclose/screens/chat/conversation_list_screen.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/chat_service.dart'
    show chatFriendlyErrorMessage;
import 'package:holdclose/theme.dart';
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
  HoldcloseDatabase db,
})> _pump(
  WidgetTester tester, {
  required ChatRepository repo,
  required HoldcloseDatabase db,
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
  late HoldcloseDatabase db;
  late ChatRepository repo;

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
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
        HoldcloseDatabase db,
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

      // Tile titles derive from the first user message via the succinct
      // formatter — assert the tile shows exactly what the formatter returns.
      expect(
        find.descendant(
          of: find.byKey(ConversationListScreen.tileKey('convo-new')),
          matching: find.text(conversationDisplayTitle(
            'When she says she wants to go home, what do I say?',
          )),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ConversationListScreen.tileKey('convo-old')),
          matching: find.text(conversationDisplayTitle(
            'What is sundowning and why does she get so agitated at dusk?',
          )),
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
        HoldcloseDatabase db,
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
        HoldcloseDatabase db,
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
            '${RegExp.escape(conversationDisplayTitle("How do I respond when he asks for his mother?"))}.*'
            'Double-tap to open this chat',
          ),
        ),
        isTrue,
      );
    });
  });

  group('ConversationListScreen — title derivation', () {
    test('ConversationListItem.displayTitle yields a succinct, word-boundary '
        'truncation when the message is long', () {
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

      final String title = item.displayTitle;
      // Succinct: short enough for a single tile line.
      expect(title.length, lessThanOrEqualTo(37));
      // Truncated long bodies end with an ellipsis.
      expect(title, endsWith('…'));
      // No mid-word cut — the visible prefix is whole words of the body.
      final String visible = title.substring(0, title.length - 1);
      expect(body.startsWith(visible), isTrue);
      expect(visible.endsWith(' '), isFalse);
      expect(title, conversationDisplayTitle(body));
    });

    test('ConversationListItem.displayTitle returns the body verbatim when '
        'short enough to fit', () {
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

  group('ConversationListScreen — preview sanitisation (alpha bug)', () {
    testWidgets('an [action:…] marker in the last message is stripped from '
        'the tile preview', (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-action',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );
      await repo.appendMessage(Message(
        id: 'a-user',
        conversationId: 'convo-action',
        role: MessageRole.user,
        body: 'Open the calendar for next month.',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      ));
      // The last turn still carries a raw tool tag on disk.
      await repo.appendMessage(Message(
        id: 'a-asst',
        conversationId: 'convo-action',
        role: MessageRole.assistant,
        body: 'I pulled up the calendar for you.\n'
            '[action:navigate target="calendar" date="2026-07-01"]',
        citations: const <String>[],
        createdAt: _fixedNow().add(const Duration(seconds: 1)),
        streamingDone: true,
      ));

      await _pump(tester, repo: repo, db: db);

      // The clean prose previews; the marker is nowhere on screen.
      expect(
        find.descendant(
          of: find.byKey(ConversationListScreen.tileKey('convo-action')),
          matching: find.text('I pulled up the calendar for you.'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('[action:'), findsNothing);
      expect(find.textContaining('target='), findsNothing);
    });

    testWidgets('a raw [chat error: DioException …] last message previews as '
        'the friendly line', (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-err',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );
      await repo.appendMessage(Message(
        id: 'e-user',
        conversationId: 'convo-err',
        role: MessageRole.user,
        body: 'Why is she pacing?',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      ));
      // The failed-turn sentinel as ChatService stores it — raw transport
      // detail and all.
      await repo.appendMessage(Message(
        id: 'e-asst',
        conversationId: 'convo-err',
        role: MessageRole.assistant,
        body: '[chat error: shim request failed: DioException '
            '[connection error]: The connection errored]',
        citations: const <String>[],
        createdAt: _fixedNow().add(const Duration(seconds: 1)),
        streamingDone: true,
      ));

      await _pump(tester, repo: repo, db: db);

      expect(
        find.descendant(
          of: find.byKey(ConversationListScreen.tileKey('convo-err')),
          matching: find.text(chatFriendlyErrorMessage),
        ),
        findsOneWidget,
      );
      // No internal/transport vocabulary leaks into the list.
      expect(find.textContaining('chat error'), findsNothing);
      expect(find.textContaining('DioException'), findsNothing);
      expect(find.textContaining('shim'), findsNothing);
    });
  });

  group('ConversationListScreen — delete a conversation (alpha bug)', () {
    testWidgets('the per-tile trash icon confirms + deletes the conversation',
        (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-del',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );
      await repo.appendMessage(Message(
        id: 'd-1',
        conversationId: 'convo-del',
        role: MessageRole.user,
        body: 'A question I want to remove later.',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      ));

      await _pump(tester, repo: repo, db: db);

      await tester.tap(
        find.byKey(ConversationListScreen.deleteIconKey('convo-del')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(ConversationListScreen.deleteDialogKey),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ConversationListScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      // Gone from the repo and from the screen (now the empty state).
      expect(await repo.listConversations(), isEmpty);
      expect(
        find.byKey(ConversationListScreen.tileKey('convo-del')),
        findsNothing,
      );
      expect(find.byKey(ConversationListScreen.emptyStateKey), findsOneWidget);
    });

    testWidgets('long-press → confirm deletes the conversation',
        (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-lp',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );

      await _pump(tester, repo: repo, db: db);

      await tester.longPress(
        find.byKey(ConversationListScreen.tileKey('convo-lp')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(ConversationListScreen.deleteDialogKey),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ConversationListScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      expect(await repo.listConversations(), isEmpty);
    });

    testWidgets('cancelling the delete dialog keeps the conversation',
        (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-keep',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );

      await _pump(tester, repo: repo, db: db);

      await tester.tap(
        find.byKey(ConversationListScreen.deleteIconKey('convo-keep')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ConversationListScreen.deleteCancelKey));
      await tester.pumpAndSettle();

      expect(await repo.listConversations(), hasLength(1));
      expect(
        find.byKey(ConversationListScreen.tileKey('convo-keep')),
        findsOneWidget,
      );
    });

    testWidgets('deleting one of two conversations leaves the other',
        (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-a',
        title: 'placeholder',
        createdAt: _fixedNow().subtract(const Duration(hours: 1)),
      );
      await repo.createConversation(
        id: 'convo-b',
        title: 'placeholder',
        createdAt: _fixedNow(),
      );

      await _pump(tester, repo: repo, db: db);

      await tester.tap(
        find.byKey(ConversationListScreen.deleteIconKey('convo-b')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ConversationListScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      final List<Conversation> remaining = await repo.listConversations();
      expect(remaining.map((Conversation c) => c.id).toList(),
          <String>['convo-a']);
      expect(
        find.byKey(ConversationListScreen.tileKey('convo-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(ConversationListScreen.tileKey('convo-b')),
        findsNothing,
      );
    });
  });

  group('ConversationListScreen — rename a chat (fb_1781115614890041)', () {
    testWidgets('a custom title is shown verbatim instead of the derived name',
        (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-ct',
        title: 'New chat',
        createdAt: _fixedNow(),
      );
      await repo.appendMessage(Message(
        id: 'ct-1',
        conversationId: 'convo-ct',
        role: MessageRole.user,
        body: 'A long opening question the derived title would truncate badly.',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      ));
      // Coach/caregiver-set name.
      await repo.renameConversation('convo-ct', 'Sundowning At Dinner');

      await _pump(tester, repo: repo, db: db);

      expect(find.text('Sundowning At Dinner'), findsOneWidget);
      // The derived succinct title is NOT used once a custom title is set
      // (the full body still appears as the dim subtitle — that's expected).
      final String derived = conversationDisplayTitle(
        'A long opening question the derived title would truncate badly.',
      );
      expect(find.text(derived), findsNothing);
    });

    testWidgets('the pencil icon opens a prefilled dialog and Save persists '
        'the new name', (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-rn',
        title: 'New chat',
        createdAt: _fixedNow(),
      );
      await repo.appendMessage(Message(
        id: 'rn-1',
        conversationId: 'convo-rn',
        role: MessageRole.user,
        body: 'How do I handle bathing refusal?',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      ));

      await _pump(tester, repo: repo, db: db);

      await tester.tap(
        find.byKey(ConversationListScreen.renameIconKey('convo-rn')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(ConversationListScreen.renameDialogKey),
        findsOneWidget,
      );
      // Field is prefilled with the current (derived) display title.
      expect(
        find.widgetWithText(TextField, 'How do I handle bathing refusal?'),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(ConversationListScreen.renameFieldKey),
        'Bathing Refusal',
      );
      await tester.tap(find.byKey(ConversationListScreen.renameSaveKey));
      await tester.pumpAndSettle();

      final Conversation? convo = await repo.getConversation('convo-rn');
      expect(convo!.title, 'Bathing Refusal');
      expect(convo.customTitle, isTrue);
      expect(find.text('Bathing Refusal'), findsOneWidget);
    });

    testWidgets('Cancel leaves the name unchanged', (WidgetTester tester) async {
      await repo.createConversation(
        id: 'convo-rc',
        title: 'New chat',
        createdAt: _fixedNow(),
      );
      await repo.appendMessage(Message(
        id: 'rc-1',
        conversationId: 'convo-rc',
        role: MessageRole.user,
        body: 'Original question',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      ));

      await _pump(tester, repo: repo, db: db);

      await tester.tap(
        find.byKey(ConversationListScreen.renameIconKey('convo-rc')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(ConversationListScreen.renameFieldKey),
        'Discarded',
      );
      await tester.tap(find.byKey(ConversationListScreen.renameCancelKey));
      await tester.pumpAndSettle();

      final Conversation? convo = await repo.getConversation('convo-rc');
      expect(convo!.customTitle, isFalse);
      expect(convo.title, 'New chat');
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
              scaffoldBackgroundColor: holdcloseColors.background,
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

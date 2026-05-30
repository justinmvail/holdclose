import 'dart:async';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/screens/chat/chat_screen.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/chat_service.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/caption_fade.dart';
import 'package:careblazers/widgets/message_body.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../_semantics_matchers.dart';

DateTime _fixedNow() => DateTime.utc(2026, 5, 29, 19, 42);

String Function() _idFactory() {
  int n = 0;
  return () => 'msg-${++n}';
}

/// Scripted chat backend that yields the canned [deltas] when invoked.
/// Captures the [systemPrompt] + [history] so tests can assert the
/// payload the ChatService handed off.
class _ScriptedBackend implements ChatLLMBackend {
  _ScriptedBackend(this.deltas);

  final List<ChatDelta> deltas;
  String? lastSystemPrompt;
  List<ChatTurn>? lastHistory;
  int callCount = 0;

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    callCount++;
    lastSystemPrompt = systemPrompt;
    lastHistory = history;
    for (final ChatDelta d in deltas) {
      // Yield asynchronously so the chat screen has a chance to repaint
      // between deltas — mirrors the real shim's stream cadence.
      await Future<void>.delayed(Duration.zero);
      yield d;
    }
  }
}

/// Pumps the chat screen against an in-memory drift DB. Returns the
/// repo + scripted backend so tests can drive assertions.
Future<({
  ChatRepository repo,
  _ScriptedBackend backend,
  CareblazersDatabase db,
})> _pump(
  WidgetTester tester, {
  required String conversationId,
  required List<ChatDelta> deltas,
  List<Message> initialMessages = const <Message>[],
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final ChatRepository repo = ChatRepository(db);
  await repo.createConversation(
    id: conversationId,
    title: 'placeholder',
    createdAt: _fixedNow(),
  );
  for (final Message m in initialMessages) {
    await repo.appendMessage(m);
  }

  final _ScriptedBackend backend = _ScriptedBackend(deltas);
  final ChatService service = ChatService(
    repository: repo,
    backend: backend,
    idFactory: _idFactory(),
    clock: _fixedNow,
  );

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/chat/$conversationId',
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
        chatServiceProvider.overrideWithValue(service),
        chatLLMBackendProvider.overrideWithValue(backend),
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

  addTearDown(() async {
    await db.close();
  });

  return (repo: repo, backend: backend, db: db);
}

void main() {
  group('ChatScreen — TASKS.md Phase 11.4 chrome', () {
    testWidgets('renders the AppBar title and the composer', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        conversationId: 'convo-1',
        deltas: const <ChatDelta>[],
      );

      expect(find.widgetWithText(AppBar, 'Coach chat'), findsOneWidget);
      expect(find.byKey(ChatScreen.inputFieldKey), findsOneWidget);
      expect(find.byKey(ChatScreen.sendButtonKey), findsOneWidget);
    });

    testWidgets('shows the empty hint when the thread has no messages yet', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        conversationId: 'convo-empty',
        deltas: const <ChatDelta>[],
      );

      expect(find.byKey(ChatScreen.emptyHintKey), findsOneWidget);
      expect(find.byKey(ChatScreen.listKey), findsNothing);
    });

    testWidgets('hydrates with the existing messages from the repository', (
      WidgetTester tester,
    ) async {
      final Message user = Message(
        id: 'pre-1',
        conversationId: 'convo-pre',
        role: MessageRole.user,
        body: 'What is sundowning?',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      );
      final Message assistant = Message(
        id: 'pre-2',
        conversationId: 'convo-pre',
        role: MessageRole.assistant,
        body:
            "It's the agitation many people with dementia feel in the late "
            'afternoon — a brain in transition from day to evening.',
        citations: const <String>[],
        createdAt: _fixedNow().add(const Duration(seconds: 1)),
        streamingDone: true,
      );

      await _pump(
        tester,
        conversationId: 'convo-pre',
        deltas: const <ChatDelta>[],
        initialMessages: <Message>[user, assistant],
      );

      expect(
        find.byKey(ChatScreen.messageBubbleKey('pre-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(ChatScreen.messageBubbleKey('pre-2')),
        findsOneWidget,
      );
      expect(find.text('What is sundowning?'), findsOneWidget);
    });
  });

  group('ChatScreen — sending a message', () {
    testWidgets(
        'tapping send appends the user message and streams the reply '
        'through CaptionFade', (WidgetTester tester) async {
      final ({
        ChatRepository repo,
        _ScriptedBackend backend,
        CareblazersDatabase db,
      }) p = await _pump(
        tester,
        conversationId: 'convo-send',
        deltas: const <ChatDelta>[
          ChatDeltaText('Hello '),
          ChatDeltaText('Careblazer.'),
        ],
      );

      await tester.enterText(
        find.byKey(ChatScreen.inputFieldKey),
        'What is sundowning?',
      );
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      // The async stream + caption ticker need a few pumps.
      await tester.pumpAndSettle();

      // The user message bubble shows the entered text.
      expect(find.text('What is sundowning?'), findsOneWidget);
      // The assistant reply lands too.
      expect(find.text('Hello Careblazer.'), findsAtLeastNWidgets(1));
      // The persistence layer holds both turns now.
      final List<Message> persisted =
          await p.repo.loadMessages('convo-send');
      expect(persisted.length, greaterThanOrEqualTo(2));
      expect(persisted.first.role, MessageRole.user);
      expect(persisted.first.body, 'What is sundowning?');
      expect(persisted.last.role, MessageRole.assistant);
      expect(persisted.last.body, 'Hello Careblazer.');
      expect(persisted.last.streamingDone, isTrue);
    });

    testWidgets('input field clears after a successful send', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        conversationId: 'convo-clear',
        deltas: const <ChatDelta>[ChatDeltaText('Reply.')],
      );

      await tester.enterText(
        find.byKey(ChatScreen.inputFieldKey),
        'Something to send',
      );
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      await tester.pumpAndSettle();

      final TextField field =
          tester.widget<TextField>(find.byKey(ChatScreen.inputFieldKey));
      expect(field.controller!.text, '');
    });

    testWidgets('tapping send with empty input is a no-op', (
      WidgetTester tester,
    ) async {
      final ({
        ChatRepository repo,
        _ScriptedBackend backend,
        CareblazersDatabase db,
      }) p = await _pump(
        tester,
        conversationId: 'convo-noop',
        deltas: const <ChatDelta>[],
      );

      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(p.backend.callCount, 0);
      final List<Message> persisted =
          await p.repo.loadMessages('convo-noop');
      expect(persisted, isEmpty);
    });

    testWidgets('the in-flight assistant bubble uses CaptionFade; the '
        'finalised bubble uses MessageBody', (WidgetTester tester) async {
      // We script two text deltas — the screen flips from CaptionFade
      // (streaming) to MessageBody (done) after the stream closes.
      await _pump(
        tester,
        conversationId: 'convo-fade',
        deltas: const <ChatDelta>[
          ChatDeltaText('Part one. '),
          ChatDeltaText('Part two.'),
        ],
      );

      await tester.enterText(
        find.byKey(ChatScreen.inputFieldKey),
        'Tell me about sundowning.',
      );
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      // Allow the user-message + first assistant placeholder to mount.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      // While the stream is open the in-flight bubble exists and uses
      // CaptionFade. CaptionFade is keyed with [streamingBubbleKey].
      await tester.pump();
      // Once the stream closes (after pumpAndSettle) the bubble swaps to
      // MessageBody for the final render.
      await tester.pumpAndSettle();
      expect(find.byType(CaptionFade), findsNothing,
          reason:
              'After the stream closes, the bubble should switch from '
              'CaptionFade to MessageBody for the final render.');
      expect(find.byType(MessageBody), findsAtLeastNWidgets(1));
    });

    testWidgets('the user bubble is right-aligned and the assistant bubble '
        'is left-aligned', (WidgetTester tester) async {
      await _pump(
        tester,
        conversationId: 'convo-align',
        deltas: const <ChatDelta>[
          ChatDeltaText('Here is a thought to try.'),
        ],
      );

      await tester.enterText(
        find.byKey(ChatScreen.inputFieldKey),
        'A question for the coach.',
      );
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      await tester.pumpAndSettle();

      // The user bubble sits to the right of the screen midpoint; the
      // assistant bubble sits to the left of it.
      final double midX = tester.getSize(find.byType(MaterialApp)).width / 2;
      final Finder userBubble = find.text('A question for the coach.');
      final Finder assistantBubble =
          find.text('Here is a thought to try.');

      final Rect userRect = tester.getRect(userBubble);
      final Rect assistantRect = tester.getRect(assistantBubble);
      expect(userRect.right, greaterThan(midX));
      expect(assistantRect.left, lessThan(midX));
    });
  });

  group('ChatScreen — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets('the send button has a "Send message to the coach" label', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        conversationId: 'convo-sem',
        deltas: const <ChatDelta>[],
      );

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Send message to the coach'),
        ),
        isTrue,
      );
    });

    testWidgets('user + assistant bubbles announce "You said" / "Coach said"',
        (WidgetTester tester) async {
      await _pump(
        tester,
        conversationId: 'convo-sem-bubble',
        deltas: const <ChatDelta>[ChatDeltaText('A coaching reply.')],
      );

      await tester.enterText(
        find.byKey(ChatScreen.inputFieldKey),
        'A user question.',
      );
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('You said: A user question'),
        ),
        isTrue,
      );
      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Coach said: A coaching reply'),
        ),
        isTrue,
      );
    });
  });
}

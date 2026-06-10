/// Integration coverage for the chat composition + streaming-reply flow
/// (BUILD_SPEC.md §5.15 Chat tab → conversation list → the pushed thread,
/// TASKS.md Phase 15.8).
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15
/// harness (in-memory drift, pinned clock, no-op TTS/analytics) and assert
/// real navigation + drift persistence — never goldens. Five caregiver
/// flows:
///   1. **Send + streaming reply** — type → Send → the user turn renders
///      right-aligned navy, the coach reply streams in left-aligned warm
///      through [CaptionFade], and the message list pins to the bottom.
///   2. **Multi-turn** — three sequential sends each draw a streamed reply;
///      the thread shows six messages in send order.
///   3. **Empty input no-op** — tapping Send with an empty field adds
///      nothing and never hits the backend.
///   4. **Streaming flag blocks a double-send race** — with the fake
///      stream slowed, a second Send mid-stream is a no-op; only the first
///      stream runs, and the second message sends once the first completes.
///   5. **Back + re-enter** — Back returns to the (still-mounted)
///      conversation list; re-entering rehydrates the thread from drift and
///      re-anchors to the latest message.
///
/// The chat surface reads two seams the base harness does not override —
/// [chatRepositoryBackendProvider] (defaults to an on-disk drift handle)
/// and [chatLLMBackendProvider] (defaults to the live shim, forbidden in
/// `test/` per BUILD_SPEC.md §6.1). Each flow injects an in-memory
/// [ChatRepository] and a [_FakeChatBackend] that streams a canned reply —
/// the test-side stand-in for the spec's `FakeLLMProvider.chatStream()`.
library;

import 'dart:async';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/screens/chat/chat_screen.dart';
import 'package:careblazers/screens/chat/conversation_list_screen.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/chat_service.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/caption_fade.dart';
import 'package:careblazers/widgets/message_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

/// The single conversation every flow seeds + opens.
const String _convoId = 'convo-1';

/// Fixed instant the seeded prior turns are stamped at — comfortably
/// before the live `DateTime.now()` the production [ChatService] stamps on
/// freshly-sent turns, so the conversation-list provider's recency sort
/// keeps the sent turns last.
final DateTime _seedClock = DateTime(2026, 5, 30, 18, 0);

Message _seedMessage(
  String id,
  MessageRole role,
  String body,
  int minuteOffset,
) =>
    Message(
      id: id,
      conversationId: _convoId,
      role: role,
      body: body,
      citations: const <String>[],
      createdAt: _seedClock.add(Duration(minutes: minuteOffset)),
      streamingDone: true,
    );

/// Scripted [ChatLLMBackend] standing in for the streaming fake the spec
/// calls `FakeLLMProvider.chatStream()`. Yields either a fixed delta list
/// or a per-call [replyBuilder] result, with an optional [deltaDelay]
/// between fragments so a test can observe the in-flight (streaming) state.
/// Records [callCount] so the double-send-race flow can prove the second
/// send never reached the backend.
class _FakeChatBackend implements ChatLLMBackend {
  _FakeChatBackend({
    this.deltaDelay = Duration.zero,
    List<ChatDelta>? fixedDeltas,
    List<ChatDelta> Function(int callIndex)? replyBuilder,
  })  : _fixedDeltas = fixedDeltas,
        _replyBuilder = replyBuilder;

  final Duration deltaDelay;
  final List<ChatDelta>? _fixedDeltas;
  final List<ChatDelta> Function(int callIndex)? _replyBuilder;

  int callCount = 0;

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    final int index = callCount;
    callCount++;
    final List<ChatDelta> deltas =
        _replyBuilder?.call(index) ?? _fixedDeltas ?? const <ChatDelta>[];
    for (final ChatDelta d in deltas) {
      // Yield asynchronously so the chat screen repaints between deltas,
      // mirroring the real shim's stream cadence.
      await Future<void>.delayed(deltaDelay);
      yield d;
    }
  }
}

/// Build an in-memory chat store, run [seed] against it, then pump the full
/// app with the chat repository + backend seams overridden. Returns the
/// container, the live repo, and the fake backend for assertions.
Future<({
  ProviderContainer container,
  ChatRepository repo,
  _FakeChatBackend backend,
})> _pumpChat(
  WidgetTester tester, {
  required _FakeChatBackend backend,
  required Future<void> Function(ChatRepository repo) seed,
}) async {
  final CareblazersDatabase db = CareblazersDatabase.testInstance();
  addTearDown(db.close);
  final ChatRepository repo = ChatRepository(db);
  await seed(repo);

  final ProviderContainer container = await pumpCareblazersApp(
    tester,
    extraOverrides: <Override>[
      chatRepositoryBackendProvider.overrideWithValue(repo),
      chatLLMBackendProvider.overrideWithValue(backend),
      // Disable the post-first-turn auto-title so `backend.callCount`
      // reflects only reply round-trips (the title pass reuses this same
      // backend; production keeps it on via chatTitleGeneratorProvider).
      chatTitleGeneratorProvider
          .overrideWithValue((List<ChatTurn> turns) async => null),
    ],
  );
  return (container: container, repo: repo, backend: backend);
}

/// Home → Chat tab → tap the seeded thread tile → [ChatScreen].
Future<void> _openThread(WidgetTester tester) async {
  await tester.tap(tabFor('Chat'));
  await tester.pumpAndSettle();
  expect(find.byType(ConversationListScreen), findsOneWidget);

  await tester.tap(find.byKey(ConversationListScreen.tileKey(_convoId)));
  await tester.pumpAndSettle();
  expect(find.byType(ChatScreen), findsOneWidget);
}

/// Type [text] into the composer and tap Send.
Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(ChatScreen.inputFieldKey), text);
}

Finder _tapSend() => find.byKey(ChatScreen.sendButtonKey);

/// A message body's bubble decoration — the closest [Container] ancestor
/// of the rendered text is the coloured bubble.
BoxDecoration _bubbleDecoration(WidgetTester tester, Finder bodyText) {
  final Container bubble = tester.widget<Container>(
    find.ancestor(of: bodyText, matching: find.byType(Container)).first,
  );
  return bubble.decoration! as BoxDecoration;
}

/// The thread's scroll controller (the [ChatScreen] owns one ScrollController
/// wired to its message [ListView]).
ScrollController _listController(WidgetTester tester) =>
    tester.widget<ListView>(find.byKey(ChatScreen.listKey)).controller!;

/// Assert the message list is pinned to the bottom. The epsilon absorbs the
/// sub-pixel gap the bottom-anchoring `animateTo` can leave when the final
/// layout pass nudges `maxScrollExtent` (observed ~1.5px on CI fonts). When
/// the thread is short enough to not scroll, both values are 0 and this
/// trivially holds.
void _expectPinnedToBottom(WidgetTester tester) {
  final ScrollController c = _listController(tester);
  expect(
    c.position.pixels,
    moreOrLessEquals(c.position.maxScrollExtent, epsilon: 8.0),
  );
}

/// Pump in small slices until the in-flight (streaming) assistant bubble
/// appears, then return — robust against the wall-clock cadence of the
/// in-memory drift writes that interleave with the fake stream's deltas.
Future<void> _pumpUntilStreaming(WidgetTester tester) async {
  for (int i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.byKey(ChatScreen.streamingBubbleKey).evaluate().isNotEmpty) {
      return;
    }
  }
  fail('the streaming assistant bubble never appeared');
}

/// Drain Home's still-mounted bare-timer streams (the night-theme /
/// quiet-hours periodics, the catch-me-up recap) so none outlive the test
/// and trip flutter_test's "Timer still pending" invariant — mirrors the
/// Phase 15.6/15.7 flows' recap flush.
Future<void> _flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Seeders
// ---------------------------------------------------------------------------

/// One conversation, no messages — the thread opens on its empty hint.
Future<void> _seedEmptyThread(ChatRepository repo) async {
  await repo.createConversation(
    id: _convoId,
    title: 'placeholder',
    createdAt: _seedClock,
  );
}

/// One conversation + three prior turns (the Phase 15.8 base setup).
Future<void> _seedThreeTurns(ChatRepository repo) async {
  await _seedEmptyThread(repo);
  await repo.appendMessage(_seedMessage(
    'seed-1',
    MessageRole.user,
    'When she asks to go home, what do I say?',
    0,
  ));
  await repo.appendMessage(_seedMessage(
    'seed-2',
    MessageRole.assistant,
    'Meet the feeling first. You might say you hear how much she wants '
        'to be home, and ask her to tell you about it.',
    1,
  ));
  await repo.appendMessage(_seedMessage(
    'seed-3',
    MessageRole.user,
    'She brought it up again at dinner tonight.',
    2,
  ));
}

/// One conversation + a long thread so the message list is genuinely
/// scrollable (20 alternating turns).
Future<void> _seedLongThread(ChatRepository repo) async {
  await _seedEmptyThread(repo);
  for (int i = 0; i < 20; i++) {
    await repo.appendMessage(_seedMessage(
      'seed-$i',
      i.isEven ? MessageRole.user : MessageRole.assistant,
      'Message $i',
      i,
    ));
  }
}

void main() {
  group('Chat — send + streaming reply (Phase 15.8)', () {
    testWidgets(
        'the user turn renders navy-right, the reply streams warm-left '
        'through CaptionFade, and the list pins to the bottom',
        (WidgetTester tester) async {
      final _FakeChatBackend backend = _FakeChatBackend(
        deltaDelay: const Duration(milliseconds: 80),
        fixedDeltas: const <ChatDelta>[
          ChatDeltaText('You might try '),
          ChatDeltaText('meeting the feeling first.'),
        ],
      );
      await _pumpChat(tester, backend: backend, seed: _seedThreeTurns);
      await _openThread(tester);

      await _type(tester, 'What about at night?');
      await tester.tap(_tapSend());

      // While the stream is open the assistant bubble fades in via
      // CaptionFade (keyed [streamingBubbleKey]).
      await _pumpUntilStreaming(tester);
      expect(find.byKey(ChatScreen.streamingBubbleKey), findsOneWidget);
      expect(find.byType(CaptionFade), findsOneWidget);

      // The user turn shows inside the list (the body also seeds the
      // PathHeader title, so scope the finder to the list).
      final Finder userInList = find.descendant(
        of: find.byKey(ChatScreen.listKey),
        matching: find.text('What about at night?'),
      );
      expect(userInList, findsOneWidget);

      await tester.pumpAndSettle();

      // Stream closed: the bubble swaps CaptionFade → MessageBody and the
      // full reply is present.
      expect(find.byType(CaptionFade), findsNothing);
      expect(find.byType(MessageBody), findsAtLeastNWidgets(1));
      final Finder replyInList = find.descendant(
        of: find.byKey(ChatScreen.listKey),
        matching: find.text('You might try meeting the feeling first.'),
      );
      expect(replyInList, findsOneWidget);

      // Alignment: user bubble right of centre, assistant bubble left.
      final double midX =
          tester.getSize(find.byType(MaterialApp)).width / 2;
      expect(tester.getRect(userInList).right, greaterThan(midX));
      expect(tester.getRect(replyInList).left, lessThan(midX));

      // Colour: navy user bubble, warm assistant bubble.
      expect(
        _bubbleDecoration(tester, userInList).color,
        careblazersColors.primary.withValues(alpha: 0.92),
      );
      expect(
        _bubbleDecoration(tester, replyInList).color,
        careblazersColors.surfaceWarm,
      );

      // The list is pinned to the bottom once the reply lands.
      _expectPinnedToBottom(tester);

      await _flushTimers(tester);
    });
  });

  group('Chat — multi-turn (Phase 15.8)', () {
    testWidgets('three sequential sends produce six messages in order',
        (WidgetTester tester) async {
      final _FakeChatBackend backend = _FakeChatBackend(
        replyBuilder: (int i) => <ChatDelta>[ChatDeltaText('Reply ${i + 1}.')],
      );
      await _pumpChat(tester, backend: backend, seed: _seedEmptyThread);
      await _openThread(tester);

      for (final String q in const <String>[
        'First question.',
        'Second question.',
        'Third question.',
      ]) {
        await _type(tester, q);
        await tester.tap(_tapSend());
        await tester.pumpAndSettle();
      }

      // Exactly three round-trips hit the backend.
      expect(backend.callCount, 3);

      // Six bubbles, user/assistant alternating, in send order (asserted by
      // strictly-increasing vertical position inside the list).
      const List<String> expected = <String>[
        'First question.',
        'Reply 1.',
        'Second question.',
        'Reply 2.',
        'Third question.',
        'Reply 3.',
      ];
      final List<double> tops = <double>[];
      for (final String text in expected) {
        final Finder f = find.descendant(
          of: find.byKey(ChatScreen.listKey),
          matching: find.text(text),
        );
        expect(f, findsOneWidget, reason: 'expected "$text" once in the thread');
        tops.add(tester.getRect(f).top);
      }
      for (int i = 1; i < tops.length; i++) {
        expect(
          tops[i],
          greaterThan(tops[i - 1]),
          reason: 'messages should render in send order',
        );
      }

      await _flushTimers(tester);
    });
  });

  group('Chat — empty input (Phase 15.8)', () {
    testWidgets('tapping Send with an empty field adds nothing',
        (WidgetTester tester) async {
      final _FakeChatBackend backend = _FakeChatBackend(
        fixedDeltas: const <ChatDelta>[ChatDeltaText('unused')],
      );
      final ({
        ProviderContainer container,
        ChatRepository repo,
        _FakeChatBackend backend,
      }) p = await _pumpChat(
        tester,
        backend: backend,
        seed: _seedEmptyThread,
      );
      await _openThread(tester);

      // Empty thread → the soft hint, no message list.
      expect(find.byKey(ChatScreen.emptyHintKey), findsOneWidget);
      expect(find.byKey(ChatScreen.listKey), findsNothing);

      await tester.tap(_tapSend());
      await tester.pumpAndSettle();

      // No backend call, no list, no persisted messages.
      expect(p.backend.callCount, 0);
      expect(find.byKey(ChatScreen.emptyHintKey), findsOneWidget);
      expect(find.byKey(ChatScreen.listKey), findsNothing);
      expect(await p.repo.loadMessages(_convoId), isEmpty);

      await _flushTimers(tester);
    });
  });

  group('Chat — streaming flag blocks a double-send race (Phase 15.8)', () {
    testWidgets('a second Send mid-stream is a no-op until the first finishes',
        (WidgetTester tester) async {
      final _FakeChatBackend backend = _FakeChatBackend(
        deltaDelay: const Duration(milliseconds: 200),
        replyBuilder: (int i) => <ChatDelta>[ChatDeltaText('Reply ${i + 1}.')],
      );
      final ({
        ProviderContainer container,
        ChatRepository repo,
        _FakeChatBackend backend,
      }) p = await _pumpChat(
        tester,
        backend: backend,
        seed: _seedEmptyThread,
      );
      await _openThread(tester);

      await _type(tester, 'First message.');
      await tester.tap(_tapSend());
      await tester.pump(); // mount user + placeholder; _sending = true
      await tester.pump(const Duration(milliseconds: 50)); // still streaming

      // Attempt a second send while the first stream is open. The Send
      // button is disabled (onTap null) during streaming, so this is a
      // no-op — and the blocked tap leaves the field text intact.
      await _type(tester, 'Second message.');
      await tester.tap(_tapSend());
      await tester.pump(const Duration(milliseconds: 50));

      expect(p.backend.callCount, 1);
      expect(
        find.descendant(
          of: find.byKey(ChatScreen.listKey),
          matching: find.text('Second message.'),
        ),
        findsNothing,
      );

      // Let the first stream finish — still just the one round-trip.
      await tester.pumpAndSettle();
      expect(p.backend.callCount, 1);
      expect(find.text('Reply 1.'), findsAtLeastNWidgets(1));

      // The field still holds 'Second message.'; sending now succeeds.
      await tester.tap(_tapSend());
      await tester.pumpAndSettle();
      expect(p.backend.callCount, 2);
      expect(
        find.descendant(
          of: find.byKey(ChatScreen.listKey),
          matching: find.text('Second message.'),
        ),
        findsOneWidget,
      );
      expect(find.text('Reply 2.'), findsAtLeastNWidgets(1));

      await _flushTimers(tester);
    });
  });

  group('Chat — back + re-enter (Phase 15.8)', () {
    testWidgets(
        'Back returns to the list; re-entering rehydrates and re-anchors '
        'to the latest message', (WidgetTester tester) async {
      final _FakeChatBackend backend = _FakeChatBackend(
        fixedDeltas: const <ChatDelta>[ChatDeltaText('unused')],
      );
      await _pumpChat(tester, backend: backend, seed: _seedLongThread);
      await _openThread(tester);

      // The thread auto-scrolls to the latest message on open.
      final ScrollController controller = _listController(tester);
      expect(controller.position.maxScrollExtent, greaterThan(0));
      _expectPinnedToBottom(tester);

      // Scroll up toward the older turns (drag the content down).
      await tester.drag(find.byKey(ChatScreen.listKey), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(
        controller.position.pixels,
        lessThan(controller.position.maxScrollExtent - 1),
      );

      // Back → the conversation list (kept mounted on the Chat branch).
      // The redundant "Back to Chat" control was removed; the parent `Chat`
      // breadcrumb crumb is the back affordance now (tapping it runs
      // `context.go('/chat')`).
      await tester.tap(pathHeaderBackTo('Chat'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationListScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);

      // Re-enter the thread.
      await tester.tap(find.byKey(ConversationListScreen.tileKey(_convoId)));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);

      // The thread rehydrated every turn from drift and re-anchored to the
      // latest message. (The screen re-scrolls to the bottom on load; the
      // per-pixel offset isn't persisted across the route pop, by design —
      // the bottom anchor is the restored position.)
      _expectPinnedToBottom(tester);
      expect(
        find.descendant(
          of: find.byKey(ChatScreen.listKey),
          matching: find.text('Message 19'),
        ),
        findsOneWidget,
      );

      await _flushTimers(tester);
    });
  });
}

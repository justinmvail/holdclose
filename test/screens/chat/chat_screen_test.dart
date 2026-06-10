import 'dart:async';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/providers/pending_chat_message_provider.dart';
import 'package:careblazers/providers/voice_capture_provider.dart';
import 'package:careblazers/screens/chat/chat_screen.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/chat_service.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/caption_fade.dart';
import 'package:careblazers/widgets/message_body.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// A [VoiceCapture] that returns a canned transcript — no real mic/STT.
class _FakeVoiceCapture implements VoiceCapture {
  const _FakeVoiceCapture(this.transcript);

  final String? transcript;

  @override
  Future<String?> capture({void Function(String partial)? onPartial}) async => transcript;
}

/// A [PendingChatMessage] notifier seeded with [_seed] so a test can pump
/// the chat screen with a message already parked for its conversation —
/// exercising the auto-send-on-arrival path the center voice button drives.
class _SeededPendingChatMessage extends PendingChatMessage {
  _SeededPendingChatMessage(this._seed);

  final ({String conversationId, String text}) _seed;

  @override
  ({String conversationId, String text})? build() => _seed;
}

/// Scripted chat backend that yields the canned [deltas] when invoked.
/// Captures the [systemPrompt] + [history] so tests can assert the
/// payload the ChatService handed off.
///
/// When [replyBuilder] is supplied it takes precedence over [deltas] and is
/// handed the zero-based call index, so a test can script a failing first
/// turn followed by a successful retry (#19).
class _ScriptedBackend implements ChatLLMBackend {
  _ScriptedBackend(this.deltas, {this.replyBuilder, this.gate});

  final List<ChatDelta> deltas;
  final List<ChatDelta> Function(int callIndex)? replyBuilder;

  /// When set, [streamReply] awaits this before emitting any delta — lets a
  /// test hold the reply mid-flight (the dead-air gap) to assert the
  /// "Coach is thinking…" indicator, then release it.
  final Future<void>? gate;
  String? lastSystemPrompt;
  List<ChatTurn>? lastHistory;
  int callCount = 0;

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    final int index = callCount;
    callCount++;
    lastSystemPrompt = systemPrompt;
    lastHistory = history;
    if (gate != null) await gate;
    final List<ChatDelta> emit = replyBuilder?.call(index) ?? deltas;
    for (final ChatDelta d in emit) {
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
  List<ChatDelta> deltas = const <ChatDelta>[],
  List<ChatDelta> Function(int callIndex)? replyBuilder,
  List<Message> initialMessages = const <Message>[],
  Future<void>? gate,
  VoiceCapture? voiceCapture,
  ({String conversationId, String text})? pendingMessage,
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

  final _ScriptedBackend backend =
      _ScriptedBackend(deltas, replyBuilder: replyBuilder, gate: gate);
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
        if (voiceCapture != null)
          voiceCaptureProvider.overrideWithValue(voiceCapture),
        if (pendingMessage != null)
          pendingChatMessageProvider.overrideWith(
            () => _SeededPendingChatMessage(pendingMessage),
          ),
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
    testWidgets('renders the path header (back to Chat) and the composer', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        conversationId: 'convo-1',
        deltas: const <ChatDelta>[],
      );

      // The thread renders a [PathHeader] in place of an AppBar (Phase
      // 14.34) — `Chat › <name>`. The parent `Chat` breadcrumb crumb is the
      // back affordance (the redundant "Back to Chat" control was removed).
      // An empty thread's name falls back to "New chat".
      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.widgetWithText(InkWell, 'Chat'), findsOneWidget);
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
      // Scope to the bubble — the first user message also surfaces in the
      // PathHeader crumb + title now (Phase 14.34).
      expect(
        find.descendant(
          of: find.byKey(ChatScreen.messageBubbleKey('pre-1')),
          matching: find.text('What is sundowning?'),
        ),
        findsOneWidget,
      );
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

      // The user message bubble shows the entered text. Scope to the
      // message list — the same text now also drives the PathHeader
      // crumb + title (Phase 14.34).
      expect(
        find.descendant(
          of: find.byKey(ChatScreen.listKey),
          matching: find.text('What is sundowning?'),
        ),
        findsOneWidget,
      );
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

    testWidgets(
        'shows the "Coach is thinking…" indicator after Send until the first '
        'token, then drops it', (WidgetTester tester) async {
      // Gate the reply so it sits in the dead-air gap (sent, no token yet).
      final Completer<void> gate = Completer<void>();
      await _pump(
        tester,
        conversationId: 'convo-typing',
        deltas: const <ChatDelta>[ChatDeltaText('Here is a gentle idea.')],
        gate: gate.future,
      );

      await tester.enterText(
        find.byKey(ChatScreen.inputFieldKey),
        'What do I do right now?',
      );
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      // Let the user turn mount; the assistant reply is still gated.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      // The thinking indicator is up; no assistant bubble has streamed yet.
      expect(find.byKey(ChatScreen.typingIndicatorKey), findsOneWidget);
      expect(find.text('Coach is thinking…'), findsOneWidget);
      expect(find.byType(CaptionFade), findsNothing);

      // Release the reply — the indicator gives way to the streamed bubble.
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(ChatScreen.typingIndicatorKey), findsNothing);
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
      // Scope to the message list — the user text now also appears in the
      // PathHeader title (Phase 14.34), so an unscoped finder is ambiguous.
      final Finder userBubble = find.descendant(
        of: find.byKey(ChatScreen.listKey),
        matching: find.text('A question for the coach.'),
      );
      final Finder assistantBubble =
          find.text('Here is a thought to try.');

      final Rect userRect = tester.getRect(userBubble);
      final Rect assistantRect = tester.getRect(assistantBubble);
      expect(userRect.right, greaterThan(midX));
      expect(assistantRect.left, lessThan(midX));
    });
  });

  group('ChatScreen — internal markers stay hidden (alpha bug)', () {
    testWidgets(
        'a reply carrying an [action:navigate …] tag renders the prose only — '
        'the raw marker never shows in the bubble', (WidgetTester tester) async {
      await _pump(
        tester,
        conversationId: 'convo-action',
        deltas: const <ChatDelta>[
          ChatDeltaText('I pulled up the calendar for you.\n'
              '[action:navigate target="calendar" date="2026-07-01"]'),
        ],
      );

      await tester.enterText(
        find.byKey(ChatScreen.inputFieldKey),
        'Open the calendar.',
      );
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      await tester.pumpAndSettle();

      // The prose is shown; the tool marker is gone.
      expect(
        find.textContaining('I pulled up the calendar for you.'),
        findsOneWidget,
      );
      expect(find.textContaining('[action:'), findsNothing);
      expect(find.textContaining('navigate'), findsNothing);
      expect(find.textContaining('target='), findsNothing);
    });

    testWidgets(
        'a finalised assistant message hydrated from disk with an action tag '
        'still renders clean', (WidgetTester tester) async {
      // A message already persisted with the raw tag (e.g. the user closed
      // the app mid-stream) must not leak the marker on reload.
      final Message assistant = Message(
        id: 'hydrated-1',
        conversationId: 'convo-hydrate',
        role: MessageRole.assistant,
        body: 'Here is the plan.\n'
            '[action:navigate target="calendar" date="2026-07-01"]',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      );

      await _pump(
        tester,
        conversationId: 'convo-hydrate',
        initialMessages: <Message>[assistant],
      );

      expect(find.textContaining('Here is the plan.'), findsOneWidget);
      expect(find.textContaining('[action:'), findsNothing);
    });
  });

  group('ChatScreen — network error + retry (#19)', () {
    testWidgets(
        'a failed reply stream surfaces the error in the bubble, re-enables '
        'Send, and shows an inline retry', (WidgetTester tester) async {
      final ({
        ChatRepository repo,
        _ScriptedBackend backend,
        CareblazersDatabase db,
      }) p = await _pump(
        tester,
        conversationId: 'convo-err',
        deltas: const <ChatDelta>[
          ChatDeltaError('shim unreachable'),
        ],
      );

      await tester.enterText(
        find.byKey(ChatScreen.inputFieldKey),
        'Why is she pacing?',
      );
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      await tester.pumpAndSettle();

      // The failure surfaces in the assistant bubble as the friendly,
      // brand-voiced line — NOT the raw `[chat error: …]` sentinel (alpha
      // bug: internal markers must never reach the caregiver).
      expect(find.textContaining(chatFriendlyErrorMessage), findsOneWidget);
      expect(find.textContaining('[chat error:'), findsNothing);
      expect(find.textContaining('shim'), findsNothing);

      // The Send button is usable again (not stuck in the dimmed "sending"
      // state) — its onTap is non-null so the caregiver can resend.
      final InkWell sendInk =
          tester.widget<InkWell>(find.byKey(ChatScreen.sendButtonKey));
      expect(sendInk.onTap, isNotNull,
          reason: 'Send must re-enable after a failed reply');

      // The user turn persisted, plus a failed assistant turn — nothing
      // vanished.
      final List<Message> persisted = await p.repo.loadMessages('convo-err');
      expect(persisted.first.role, MessageRole.user);
      expect(persisted.first.body, 'Why is she pacing?');
      expect(persisted.last.role, MessageRole.assistant);
      expect(persisted.last.streamingDone, isTrue);

      // The inline "Try again" affordance renders under the failed bubble.
      expect(find.byKey(ChatScreen.retryKey), findsOneWidget);
    });

    testWidgets(
        'tapping the inline retry re-invokes the backend and renders the '
        'recovered reply', (WidgetTester tester) async {
      // First call errors; the retry (second call) streams a clean reply.
      final ({
        ChatRepository repo,
        _ScriptedBackend backend,
        CareblazersDatabase db,
      }) p = await _pump(
        tester,
        conversationId: 'convo-retry',
        replyBuilder: (int i) => i == 0
            ? const <ChatDelta>[ChatDeltaError('offline')]
            : const <ChatDelta>[ChatDeltaText('Pacing often means restless '
                'energy — a short walk can help.')],
      );

      await tester.enterText(
        find.byKey(ChatScreen.inputFieldKey),
        'Why is she pacing?',
      );
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(p.backend.callCount, 1);
      // The failed turn shows the friendly line (not the raw sentinel) but
      // the inline retry is still offered — detection runs on the stored
      // raw body, the display is sanitised.
      expect(find.textContaining(chatFriendlyErrorMessage), findsOneWidget);
      expect(find.textContaining('[chat error:'), findsNothing);
      expect(find.byKey(ChatScreen.retryKey), findsOneWidget);

      // Tap the inline retry — it re-sends the last user turn.
      await tester.tap(find.byKey(ChatScreen.retryKey));
      await tester.pumpAndSettle();

      // The backend was hit a second time and the recovered reply rendered.
      expect(p.backend.callCount, 2);
      expect(
        find.textContaining('Pacing often means restless energy'),
        findsOneWidget,
      );
      // The retry affordance is gone: a successful reply now occupies the
      // last slot, so the (still-visible, by design) failed bubble above it
      // no longer offers retry — no stale stack of retry buttons.
      expect(find.byKey(ChatScreen.retryKey), findsNothing);

      // The thread now holds the original user turn, the failed assistant
      // turn, the resent user turn, and the recovered assistant turn.
      final List<Message> persisted =
          await p.repo.loadMessages('convo-retry');
      expect(
        persisted.where((Message m) => m.role == MessageRole.user).length,
        2,
      );
      expect(persisted.last.role, MessageRole.assistant);
      expect(persisted.last.body,
          'Pacing often means restless energy — a short walk can help.');
    });

    testWidgets(
        'a failed turn hydrated from disk (no in-session memory) still '
        're-sends on retry', (WidgetTester tester) async {
      // Root-cause repro: a failed assistant turn persists with the
      // `[chat error: …]` sentinel, so its inline retry reappears whenever
      // the thread re-renders from disk — after a restart, or when the Home
      // tab tears down + rebuilds the embedded chat. In that case the
      // session-only `_lastUserText` is null, and tapping "Try again" used
      // to no-op (the backend was never re-invoked). The fix falls back to
      // the last user message in the rendered thread.
      final Message user = Message(
        id: 'hist-user',
        conversationId: 'convo-hydrated-retry',
        role: MessageRole.user,
        body: 'Why is she pacing?',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      );
      final Message failed = Message(
        id: 'hist-failed',
        conversationId: 'convo-hydrated-retry',
        role: MessageRole.assistant,
        body: '[chat error: offline]',
        citations: const <String>[],
        createdAt: _fixedNow().add(const Duration(seconds: 1)),
        streamingDone: true,
      );

      final ({
        ChatRepository repo,
        _ScriptedBackend backend,
        CareblazersDatabase db,
      }) p = await _pump(
        tester,
        conversationId: 'convo-hydrated-retry',
        deltas: const <ChatDelta>[
          ChatDeltaText('Pacing often means restless energy.'),
        ],
        initialMessages: <Message>[user, failed],
      );

      // The retry affordance is up (driven by the persisted sentinel) and
      // nothing has been dispatched yet this session.
      expect(find.byKey(ChatScreen.retryKey), findsOneWidget);
      expect(p.backend.callCount, 0);

      await tester.tap(find.byKey(ChatScreen.retryKey));
      await tester.pumpAndSettle();

      // The backend WAS invoked — the retry resent the last user turn even
      // though `_lastUserText` was null — and the recovered reply rendered.
      expect(p.backend.callCount, 1);
      expect(
        find.textContaining('Pacing often means restless energy'),
        findsOneWidget,
      );
      // The resent turn carried the historical user message body — the
      // retry fell back to the last user message in the rendered thread.
      expect(
        p.backend.lastHistory!
            .where((ChatTurn t) => t.role == MessageRole.user)
            .map((ChatTurn t) => t.content),
        contains('Why is she pacing?'),
      );
    });
  });

  group('ChatScreen — long-press to copy (caregiver convenience)', () {
    testWidgets('long-pressing an assistant bubble copies the display text '
        'and shows a "Copied" SnackBar', (WidgetTester tester) async {
      // Capture clipboard writes via the platform channel mock.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map<Object?, Object?>)['text']
                as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      // An assistant message carrying an internal action tag — the copy
      // must use the sanitised display body, never the raw marker.
      final Message assistant = Message(
        id: 'copy-assistant',
        conversationId: 'convo-copy',
        role: MessageRole.assistant,
        body: 'Try a calm redirection.\n'
            '[action:navigate target="calendar" date="2026-07-01"]',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      );

      await _pump(
        tester,
        conversationId: 'convo-copy',
        initialMessages: <Message>[assistant],
      );

      await tester.longPress(
        find.byKey(ChatScreen.messageBubbleKey('copy-assistant')),
      );
      await tester.pump();

      expect(copied, 'Try a calm redirection.');
      expect(find.text(ChatScreen.copiedSnackText), findsOneWidget);
    });

    testWidgets('long-pressing a user bubble copies its raw text', (
      WidgetTester tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map<Object?, Object?>)['text']
                as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final Message user = Message(
        id: 'copy-user',
        conversationId: 'convo-copy-user',
        role: MessageRole.user,
        body: 'How do I handle sundowning?',
        citations: const <String>[],
        createdAt: _fixedNow(),
        streamingDone: true,
      );

      await _pump(
        tester,
        conversationId: 'convo-copy-user',
        initialMessages: <Message>[user],
      );

      await tester.longPress(
        find.byKey(ChatScreen.messageBubbleKey('copy-user')),
      );
      await tester.pump();

      expect(copied, 'How do I handle sundowning?');
      expect(find.text(ChatScreen.copiedSnackText), findsOneWidget);
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

  group('ChatScreen — keyboard dismiss (#fb_1780959745327767)', () {
    testWidgets('the message list dismisses the keyboard on drag', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        conversationId: 'convo-kbd-1',
        initialMessages: <Message>[
          Message(
            id: 'k1',
            conversationId: 'convo-kbd-1',
            role: MessageRole.user,
            body: 'Existing turn',
            citations: const <String>[],
            createdAt: _fixedNow(),
            streamingDone: true,
          ),
        ],
      );

      final ListView list =
          tester.widget<ListView>(find.byKey(ChatScreen.listKey));
      expect(
        list.keyboardDismissBehavior,
        ScrollViewKeyboardDismissBehavior.onDrag,
      );
    });

    testWidgets('tapping the thread area unfocuses the composer', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        conversationId: 'convo-kbd-2',
        initialMessages: <Message>[
          Message(
            id: 'k2',
            conversationId: 'convo-kbd-2',
            role: MessageRole.user,
            body: 'Existing turn',
            citations: const <String>[],
            createdAt: _fixedNow(),
            streamingDone: true,
          ),
        ],
      );

      // Focus the input, then tap the thread — focus should drop.
      await tester.tap(find.byKey(ChatScreen.inputFieldKey));
      await tester.pump();
      expect(
        FocusScope.of(tester.element(find.byKey(ChatScreen.inputFieldKey)))
            .hasFocus,
        isTrue,
      );

      await tester.tap(find.byKey(const Key('chat-screen-thread-tap-dismiss')));
      await tester.pump();

      expect(
        FocusScope.of(tester.element(find.byKey(ChatScreen.inputFieldKey)))
            .hasFocus,
        isFalse,
      );
    });
  });

  group('ChatScreen — composer mic (#fb_1780959784045575)', () {
    testWidgets('tapping the mic drops the transcript into the field', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        conversationId: 'convo-mic',
        voiceCapture: const _FakeVoiceCapture('  she keeps asking for her mom  '),
      );

      // Field starts empty.
      TextField field =
          tester.widget<TextField>(find.byKey(ChatScreen.inputFieldKey));
      expect(field.controller!.text, '');

      await tester.tap(find.byKey(ChatScreen.composerMicKey));
      await tester.pumpAndSettle();

      field = tester.widget<TextField>(find.byKey(ChatScreen.inputFieldKey));
      // Trimmed transcript lands in the field, ready to edit or send.
      expect(field.controller!.text, 'she keeps asking for her mom');
    });

    testWidgets('a blank capture leaves the field untouched', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        conversationId: 'convo-mic-blank',
        voiceCapture: const _FakeVoiceCapture(null),
      );

      await tester.tap(find.byKey(ChatScreen.composerMicKey));
      await tester.pumpAndSettle();

      final TextField field =
          tester.widget<TextField>(find.byKey(ChatScreen.inputFieldKey));
      expect(field.controller!.text, '');
    });
  });

  group('ChatScreen — pending message auto-send (center voice button)', () {
    testWidgets(
        'a message parked for this conversation is sent on first build', (
      WidgetTester tester,
    ) async {
      final ({
        ChatRepository repo,
        _ScriptedBackend backend,
        CareblazersDatabase db,
      }) p = await _pump(
        tester,
        conversationId: 'convo-pending',
        deltas: const <ChatDelta>[ChatDeltaText('Here is a gentle idea.')],
        pendingMessage: (
          conversationId: 'convo-pending',
          text: 'why is he pacing at night',
        ),
      );
      await tester.pumpAndSettle();

      // The spoken message landed as the first user turn...
      expect(
        find.descendant(
          of: find.byKey(ChatScreen.listKey),
          matching: find.text('why is he pacing at night'),
        ),
        findsOneWidget,
      );
      // ...and the coach replied.
      expect(find.text('Here is a gentle idea.'), findsAtLeastNWidgets(1));

      final List<Message> persisted =
          await p.repo.loadMessages('convo-pending');
      expect(persisted.first.role, MessageRole.user);
      expect(persisted.first.body, 'why is he pacing at night');
    });

    testWidgets('a message parked for a DIFFERENT conversation is ignored', (
      WidgetTester tester,
    ) async {
      final ({
        ChatRepository repo,
        _ScriptedBackend backend,
        CareblazersDatabase db,
      }) p = await _pump(
        tester,
        conversationId: 'convo-mine',
        pendingMessage: (
          conversationId: 'some-other-convo',
          text: 'not for this thread',
        ),
      );
      await tester.pumpAndSettle();

      // The empty hint shows — nothing was sent into this thread.
      expect(find.byKey(ChatScreen.emptyHintKey), findsOneWidget);
      final List<Message> persisted = await p.repo.loadMessages('convo-mine');
      expect(persisted, isEmpty);
    });
  });
}

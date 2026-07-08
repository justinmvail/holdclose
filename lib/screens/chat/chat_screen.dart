import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/chat.dart';
import '../../providers/pending_chat_message_provider.dart';
import '../../providers/voice_capture_provider.dart';
import '../../services/chat_actions.dart' show chatNavigateRequestProvider;
import '../../services/chat_repository.dart';
import '../../services/chat_service.dart';
import '../../services/voice_intake.dart';
import '../../theme.dart';
import '../../widgets/caption_fade.dart';
import '../../widgets/message_body.dart';
import '../../widgets/path_header.dart';
import 'conversation_list_screen.dart';

/// Multi-turn chat with the caregiving coach (TASKS.md Phase 11.4).
///
/// Layout:
///   - A [PathHeader] (`Chat › <conversation name>`, back to Chat) at the
///     top of the body — the thread is pushed inside the Chat shell
///     branch from `/chat`, so Back pops to the conversation list (Phase
///     14.34). The Home tab swaps this for its own [appBarOverride].
///   - Scrolling message list:
///     * Assistant messages: warm-coach styling — surfaceWarm bubble,
///       left-aligned, body text in `bodyLarge`. While the assistant
///       message is still streaming, the body fades in word-by-word via
///       [CaptionFade] (same visual language as the decoder result
///       screen, BUILD_SPEC.md §5.4 + §11.6).
///     * User messages: navy bubble, right-aligned, white text.
///   - Input row pinned to the bottom: multiline text field + circular
///     salmon send button.
///
/// State management: messages are loaded once on init via
/// [ChatRepository.loadMessages], then a local id-keyed map merges
/// streaming snapshots from [ChatService.sendMessage]. Drift's repo
/// itself isn't a stream, so the screen owns the in-memory view of the
/// thread — the source of truth on disk gets a fresh copy on every
/// delta, but the screen never re-queries between deltas.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    required this.conversationId,
    this.appBarOverride,
    this.composerPrefix,
  });

  final String conversationId;

  /// AppBar to render in place of the thread's default in-body
  /// [PathHeader]. Used by the Home tab to surface tab-root chrome
  /// (Today title, settings gear, history button) without re-rolling the
  /// whole chat surface. When non-null the PathHeader is suppressed.
  final PreferredSizeWidget? appBarOverride;

  /// Optional widget rendered immediately above the input composer.
  /// Used by the Home tab to surface the "Log a journal entry" quick
  /// action without dragging that chip rail into every chat surface.
  final Widget? composerPrefix;

  static const Key inputFieldKey = Key('chat-screen-input');
  static const Key sendButtonKey = Key('chat-screen-send');
  static const Key listKey = Key('chat-screen-list');
  static const Key emptyHintKey = Key('chat-screen-empty-hint');

  /// The composer mic button (#fb_1780959784045575) — captures one spoken
  /// phrase and drops the transcript into the message field for the
  /// caregiver to edit or send.
  static const Key composerMicKey = Key('chat-screen-composer-mic');

  /// Inline "Try again" affordance rendered under an assistant bubble whose
  /// reply stream failed (#19). Tapping it re-sends the last user turn so the
  /// caregiver can retry without retyping; the composer also stays usable.
  static const Key retryKey = Key('chat-screen-retry');

  /// Stable per-bubble key so widget + golden tests can find a specific
  /// message without depending on its visible body.
  static Key messageBubbleKey(String messageId) =>
      Key('chat-screen-bubble-$messageId');

  /// SnackBar copy shown after a long-press copies a bubble's text to the
  /// clipboard. Exposed so the widget test can assert it surfaced.
  static const String copiedSnackText = 'Copied';

  /// Marks the currently-streaming assistant bubble so tests can assert
  /// the in-flight presentation (CaptionFade + soft "typing" affordance)
  /// independently of the message id.
  static const Key streamingBubbleKey = Key('chat-screen-streaming-bubble');

  /// The "Coach is thinking…" indicator shown after Send while we wait for
  /// the shim's first token — i.e. the dead-air gap before any assistant
  /// bubble exists. Lets the caregiver know something's happening.
  static const Key typingIndicatorKey = Key('chat-screen-typing-indicator');

  /// The always-visible one-line disclaimer under the composer — the
  /// trusted, code-side counterpart of the decoder result's footer
  /// (CLAUDE.md: medical-advice guardrails are non-negotiable).
  static const Key disclaimerKey = Key('chat-screen-disclaimer');

  /// Disclaimer copy. Short, brand-voiced, no exclamation marks.
  static const String disclaimerText =
      'Coaching support, not medical advice. In an emergency, call 911.';

  /// Confirm-card keys for a pending destructive action (delete/cancel)
  /// the coach proposed — the action runs ONLY via the confirm button.
  static Key pendingActionCardKey(String citation) =>
      Key('chat-pending-action-$citation');
  static Key pendingActionConfirmKey(String citation) =>
      Key('chat-pending-action-confirm-$citation');
  static Key pendingActionDeclineKey(String citation) =>
      Key('chat-pending-action-decline-$citation');

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

/// Tap-target wrapping the thread so a tap outside the composer dismisses
/// the keyboard (#fb_1780959745327767).
const Key _threadTapDismissKey = Key('chat-screen-thread-tap-dismiss');

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Map<String, Message> _messages = <String, Message>{};

  /// Insertion order of message ids — drift's loadMessages returns
  /// chronological order; new messages from sendMessage append. Keeping
  /// this explicit (vs. resorting by createdAt) means a streaming
  /// assistant message holds its slot even though its body changes on
  /// every delta.
  final List<String> _order = <String>[];

  StreamSubscription<Message>? _sendSubscription;
  StreamController<String>? _streamingBodyController;
  String? _streamingAssistantId;
  bool _sending = false;
  bool _hydrated = false;

  /// The text of the most recent user turn dispatched this session. Held so
  /// the inline "Try again" affordance under a failed assistant bubble can
  /// re-send it verbatim without the caregiver retyping (#19).
  String? _lastUserText;

  /// The thread row, loaded once on init. Carries the short coach-generated /
  /// caregiver-edited title the header prefers over a first-message
  /// truncation; null until [_loadInitial] resolves (header falls back to the
  /// derived name).
  Conversation? _conversation;

  /// Set when the app leaves the foreground while a reply is mid-stream. iOS
  /// suspends the network socket the moment the phone locks / the app
  /// backgrounds, so an in-flight reply stalls or errors. On return to the
  /// foreground we use this to auto-recover the turn (sleep bug) instead of
  /// leaving a dead/partial bubble the caregiver has to retry by hand.
  bool _interruptedWhileSending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitial();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Note an in-flight send so we can recover it on resume — the OS is
        // about to suspend our connection.
        if (_sending) _interruptedWhileSending = true;
      case AppLifecycleState.resumed:
        unawaited(_resumeInterruptedSend());
    }
  }

  /// Recover a reply that was interrupted by the phone sleeping / the app
  /// backgrounding mid-stream. On return to the foreground, if the last turn
  /// never completed cleanly — a failed or still-partial assistant bubble, or
  /// a stream still hung on the dead socket — re-send the caregiver's
  /// question once (the same path the inline "Try again" uses). A reply that
  /// DID land cleanly is left untouched, and the one-shot flag bounds this to
  /// a single auto-attempt per interruption so a persistently-down backend
  /// can't loop.
  Future<void> _resumeInterruptedSend() async {
    if (!_interruptedWhileSending) return;
    _interruptedWhileSending = false;

    final Message? last = _latestMessage();
    final bool replyComplete = last != null &&
        last.role == MessageRole.assistant &&
        last.streamingDone &&
        !chatBodyHasError(last.body);
    if (replyComplete) return;

    final String? text = _lastUserText ?? _lastUserMessageBody();
    if (text == null || text.isEmpty) return;

    // The interrupted stream may still be hung on a dead socket, leaving
    // `_sending` true. Drop it so `_dispatch`'s in-flight guard doesn't
    // no-op the recovery, then re-send.
    if (_sending) {
      await _sendSubscription?.cancel();
      if (mounted) {
        setState(() {
          _sending = false;
          _streamingAssistantId = null;
        });
      }
    }
    await _dispatch(text);
  }

  /// The most-recently appended message in the rendered thread, or null when
  /// the thread is empty. Used to decide whether an interrupted send already
  /// recovered on its own before the app returned to the foreground.
  Message? _latestMessage() {
    for (final String id in _order.reversed) {
      final Message? m = _messages[id];
      if (m != null) return m;
    }
    return null;
  }

  Future<void> _loadInitial() async {
    final ChatRepository repo = ref.read(chatRepositoryProvider);
    final List<Message> initial = await repo.loadMessages(widget.conversationId);
    // Load the thread row too so the header can show its short coach-generated
    // or caregiver-edited title (fb_1781128985319900 — "title still too long")
    // instead of a long truncation of the first message.
    final Conversation? convo =
        await repo.getConversation(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _hydrated = true;
      _conversation = convo;
      for (final Message m in initial) {
        if (!_messages.containsKey(m.id)) _order.add(m.id);
        _messages[m.id] = m;
      }
    });
    _scrollToBottom();
    _consumePendingMessage();
  }

  /// Auto-send a message parked for THIS conversation by the bottom-bar
  /// center voice button (the spoken-message-as-first-turn flow). Reads
  /// the one-shot slot keyed by conversation id; a non-null result is
  /// dispatched exactly once, since [PendingChatMessage.take] clears the
  /// slot. A thread reached any other way (a tile tap, a deep link) finds
  /// nothing waiting and no-ops.
  void _consumePendingMessage() {
    final String? pending = ref
        .read(pendingChatMessageProvider.notifier)
        .take(widget.conversationId);
    if (pending == null || pending.trim().isEmpty) return;
    unawaited(_dispatch(pending.trim()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sendSubscription?.cancel();
    _streamingBodyController?.close();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Composer Send handler — pulls the field text, clears it, and dispatches.
  Future<void> _send() async {
    final String text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    await _dispatch(text);
  }

  /// Re-send the last user turn after a failed reply (#19). The composer's
  /// own Send already re-enables on error (the `_sending` flag is cleared in
  /// the `finally` below), so this is purely a convenience — one tap instead
  /// of retyping. No-op while a stream is already in flight.
  ///
  /// [_lastUserText] is session-only memory of the last dispatch. But a
  /// failed turn is persisted with the `[chat error: …]` sentinel, so its
  /// retry affordance reappears whenever the thread is re-rendered from disk
  /// — after the app restarts, or when the Home tab tears down + rebuilds the
  /// embedded chat. In that case [_lastUserText] is null even though a
  /// retryable failed bubble is on screen, and tapping "Try again" was a
  /// no-op. So fall back to the most recent user message in the rendered
  /// thread, which always reflects what's actually shown.
  Future<void> _retryLast() async {
    if (_sending) return;
    final String? text = _lastUserText ?? _lastUserMessageBody();
    if (text == null || text.isEmpty) return;
    await _dispatch(text);
  }

  /// The body of the most recent user message in the rendered thread, or
  /// null when none has been sent. Walks [_order] back-to-front so it
  /// survives a state recreation (where [_lastUserText] resets to null).
  String? _lastUserMessageBody() {
    for (final String id in _order.reversed) {
      final Message? m = _messages[id];
      if (m != null && m.role == MessageRole.user) return m.body;
    }
    return null;
  }

  /// Shared dispatch path for both [_send] and [_retryLast]: flips the
  /// sending flag, opens a fresh streaming-body controller, subscribes to
  /// the reply stream, and clears the sending flag when the stream closes —
  /// crucially in a `finally`, so a stream that ERRORS still re-enables the
  /// Send button (no stuck "sending" state).
  Future<void> _dispatch(String text) async {
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _lastUserText = text;
    });

    final ChatService svc = ref.read(chatServiceProvider);
    final Stream<Message> stream = svc.sendMessage(
      conversationId: widget.conversationId,
      userText: text,
    );

    // Open a fresh body-stream controller — CaptionFade reuses its
    // ticker across emissions and fades only the newly-appearing
    // words, which is exactly the visual the decoder result screen
    // uses for its partial streaming output.
    await _streamingBodyController?.close();
    _streamingBodyController = StreamController<String>.broadcast();

    unawaited(_sendSubscription?.cancel());
    final Completer<void> done = Completer<void>();
    _sendSubscription = stream.listen(
      _onMessageDelta,
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e, StackTrace _) {
        if (!done.isCompleted) done.complete();
      },
    );

    try {
      await done.future;
    } finally {
      // Always drop the sending flag — on a clean close AND on an errored
      // stream — so the Send button re-enables and the caregiver can retry
      // by resending (#19). Without the `finally`, an exception escaping the
      // await would strand the composer in a permanent "sending" state.
      if (mounted) {
        setState(() {
          _sending = false;
          _streamingAssistantId = null;
        });
      }
    }
    if (!mounted) return;
    // Invalidate the conversation list so the parent route's tile
    // reflects the freshly-sent user message + the assistant's reply
    // when the user navigates back.
    ref.invalidate(chatConversationListProvider);
  }

  void _onMessageDelta(Message m) {
    if (!mounted) return;
    setState(() {
      if (!_messages.containsKey(m.id)) _order.add(m.id);
      _messages[m.id] = m;
      if (m.role == MessageRole.assistant && !m.streamingDone) {
        _streamingAssistantId = m.id;
        // Sanitise every streamed snapshot — strip `[action:…]` tags and
        // swap a raw `[chat error: …]` trailer for the friendly line — so
        // the in-flight CaptionFade never flashes an internal marker.
        _streamingBodyController?.add(ChatService.displayBody(m.body));
      } else if (m.role == MessageRole.assistant && m.streamingDone) {
        // Final body lands — push one last emission so CaptionFade fades
        // the trailing tokens before the bubble swaps to the static
        // MessageBody (which renders citation chips).
        _streamingBodyController?.add(ChatService.displayBody(m.body));
      }
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    // Defer until the next frame — the new bubble hasn't laid out
    // yet, so `maxScrollExtent` is still the pre-insert value.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// Display name for the thread — the first user message's first 60
  /// chars (shared with the conversation-list tile via
  /// [conversationDisplayTitle]), or "New chat" before the caregiver has
  /// typed. Drives the [PathHeader] crumb + title (Phase 14.34).
  String get _conversationName {
    // A coach-generated or caregiver-edited title wins — it's a short 2-5 word
    // label, so the header stays on one line instead of wrapping a long
    // first-message truncation (fb_1781128985319900).
    final Conversation? c = _conversation;
    if (c != null && c.customTitle && c.title.trim().isNotEmpty) {
      return conversationDisplayTitle(c.title);
    }
    for (final String id in _order) {
      final Message? m = _messages[id];
      if (m != null && m.role == MessageRole.user) {
        return conversationDisplayTitle(m.body);
      }
    }
    return conversationDisplayTitle(null);
  }

  @override
  Widget build(BuildContext context) {
    final List<Message> ordered = <Message>[
      for (final String id in _order)
        if (_messages.containsKey(id)) _messages[id]!,
    ];

    // When the coach runs an [action:navigate …], it parks the target route
    // here; push it, then clear the intent so a later rebuild doesn't
    // re-fire the same navigation.
    ref.listen<String?>(chatNavigateRequestProvider,
        (String? previous, String? next) {
      if (next == null) return;
      ref.read(chatNavigateRequestProvider.notifier).clear();
      context.push(next);
    });

    return Scaffold(
      backgroundColor: context.hc.background,
      // The Home tab passes its own [appBarOverride]; the `/chat/:id`
      // thread leaves it null and renders a [PathHeader] inside the body
      // instead (Phase 14.34) — `Chat › <conversation name>`, back to the
      // Chat list (which the thread popped from inside the Chat shell
      // branch).
      appBar: widget.appBarOverride,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (widget.appBarOverride == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: PathHeader(
                  breadcrumbs: <PathHeaderCrumb>[
                    const PathHeaderCrumb(label: 'Chat', route: '/chat'),
                    PathHeaderCrumb(label: _conversationName),
                  ],
                  title: _conversationName,
                  backLabel: 'Back to Chat',
                  leadingIcon: Icons.chat_bubble_outline,
                ),
              ),
            Expanded(
              // Tap anywhere in the thread (outside the composer) to
              // dismiss the keyboard (#fb_1780959745327767). Paired with
              // the ListView's drag-dismiss below so the caregiver always
              // has a way to put the keyboard away — by tapping the thread
              // or by scrolling it.
              child: GestureDetector(
                key: _threadTapDismissKey,
                behavior: HitTestBehavior.opaque,
                onTap: () => FocusScope.of(context).unfocus(),
                child: _hydrated && ordered.isEmpty
                    ? const _EmptyHint()
                    : ListView.builder(
                        key: ChatScreen.listKey,
                        controller: _scroll,
                        // Drag the thread to dismiss the keyboard
                        // (#fb_1780959745327767).
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                        itemCount: ordered.length,
                      itemBuilder: (BuildContext context, int index) {
                        final Message m = ordered[index];
                        final bool isStreaming = m.id == _streamingAssistantId;
                        // Only the LAST bubble offers retry — "the most recent
                        // attempt failed; resend it." A successful reply later
                        // pushes the failed bubble out of the last slot, so its
                        // retry drops (no stale stack of retry buttons), while
                        // history still keeps the failed turn visible.
                        final bool isLast = index == ordered.length - 1;
                        return _MessageRow(
                          message: m,
                          streamingBodyStream: isStreaming
                              ? _streamingBodyController?.stream
                              : null,
                          isStreaming: isStreaming,
                          // Null while a stream is in flight (no double-send
                          // race) and on every non-final bubble.
                          onRetry:
                              (!_sending && isLast) ? _retryLast : null,
                          onPendingDecision: (String citation,
                                  {required bool confirmed}) =>
                              _resolvePendingAction(
                            m,
                            citation,
                            confirmed: confirmed,
                          ),
                        );
                      },
                    ),
              ),
            ),
            if (widget.composerPrefix != null) widget.composerPrefix!,
            _Composer(
              controller: _input,
              sending: _sending,
              onSend: _send,
            ),
            // Trusted, code-side medical-advice reminder — the chat/voice
            // counterpart of the decoder result's footer. Always visible;
            // never sourced from model output.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                ChatScreen.disclaimerText,
                key: ChatScreen.disclaimerKey,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.hc.primarySoft,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Resolve a pending destructive-action confirm card: run it (confirm)
  /// or discard it (keep) through the service, then refresh this thread's
  /// messages from the repository so the card disappears in place.
  Future<void> _resolvePendingAction(
    Message message,
    String citation, {
    required bool confirmed,
  }) async {
    final ChatService service = ref.read(chatServiceProvider);
    bool ran = false;
    if (confirmed) {
      ran = await service.confirmPendingAction(
        conversationId: message.conversationId,
        messageId: message.id,
        citation: citation,
      );
    } else {
      await service.declinePendingAction(
        conversationId: message.conversationId,
        messageId: message.id,
        citation: citation,
      );
    }
    final List<Message> fresh =
        await service.repository.loadMessages(message.conversationId);
    if (!mounted) return;
    setState(() {
      for (final Message m in fresh) {
        if (_messages.containsKey(m.id)) _messages[m.id] = m;
      }
    });
    if (!confirmed) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ran
                ? 'Done.'
                : "We couldn't make that change. Please try it from its "
                    'screen.',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

/// Soft hint shown when the conversation has no messages yet.
class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: ChatScreen.emptyHintKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.chat_bubble_outline,
            size: 48,
            color: context.hc.primarySoft,
          ),
          const SizedBox(height: 12),
          Text(
            'Ask anything.',
            style: textTheme.headlineMedium?.copyWith(
              color: context.hc.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            "What is sundowning? Why is she accusing me? What can I "
            "say when he asks for his mom?",
            style: textTheme.bodyMedium?.copyWith(
              color: context.hc.primarySoft,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// One row in the message list. Branches on [Message.role] for the two
/// visually-distinct bubbles (BUILD_SPEC.md / TASKS.md Phase 11.4):
///   - user: navy bubble, white text, right-aligned.
///   - assistant: surfaceWarm bubble, navy text, left-aligned. When
///     [isStreaming] is true the body comes through [CaptionFade] with
///     the streaming body stream.
/// "Coach is thinking…" content shown inside the streaming assistant bubble
/// while the shim composes a reply but hasn't streamed its first token yet —
/// a brand-tinted spinner + calm line (same idiom as the decoder result
/// screen's loading state), in place of an otherwise-blank bubble.
class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: context.hc.primarySoft,
          fontStyle: FontStyle.italic,
        );
    return Semantics(
      label: 'Coach is thinking',
      child: Row(
        key: ChatScreen.typingIndicatorKey,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                context.hc.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('Coach is thinking…', style: style),
        ],
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.streamingBodyStream,
    required this.isStreaming,
    this.onRetry,
    this.onPendingDecision,
  });

  final Message message;
  final Stream<String>? streamingBodyStream;
  final bool isStreaming;

  /// Re-send the last user turn. Non-null only when a retry is currently
  /// allowed (no stream in flight); the bubble itself decides whether to
  /// show the affordance based on [chatBodyHasError].
  final VoidCallback? onRetry;

  /// Resolve a pending destructive-action confirm card on this message
  /// (confirmed = run it, false = keep things as they are).
  final void Function(String citation, {required bool confirmed})?
      onPendingDecision;

  @override
  Widget build(BuildContext context) {
    final bool isUser = message.role == MessageRole.user;
    final TextTheme textTheme = Theme.of(context).textTheme;

    final Widget bubble;
    if (isUser) {
      bubble = _UserBubble(
        message: message,
        textStyle: textTheme.bodyLarge?.copyWith(
          color: Colors.white,
        ),
      );
    } else {
      bubble = _AssistantBubble(
        message: message,
        streamingBodyStream: streamingBodyStream,
        isStreaming: isStreaming,
        onRetry: onRetry,
        onPendingDecision: onPendingDecision,
        textStyle: textTheme.bodyLarge?.copyWith(
          color: context.hc.primary,
          height: 1.4,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82,
          ),
          // Long-press a bubble to copy its text. User bubbles copy the
          // raw body; assistant bubbles copy [ChatService.displayBody] so
          // internal `[action:…]` / `[chat error: …]` markers never land on
          // the clipboard. Streaming bubbles aren't copyable yet — the body
          // is still in flight.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: isStreaming
                ? null
                : () => _copyBody(context, isUser: isUser),
            child: bubble,
          ),
        ),
      ),
    );
  }

  /// Copy this message's displayed text to the clipboard + confirm with a
  /// brief SnackBar. Assistant text runs through [ChatService.displayBody]
  /// so the caregiver never copies an internal marker.
  Future<void> _copyBody(BuildContext context, {required bool isUser}) async {
    final String text =
        isUser ? message.body : ChatService.displayBody(message.body);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text(ChatScreen.copiedSnackText),
          duration: Duration(seconds: 1),
        ),
      );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message, required this.textStyle});

  final Message message;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'You said: ${message.body}',
      child: Container(
        key: ChatScreen.messageBubbleKey(message.id),
        decoration: BoxDecoration(
          // Subtle navy per spec: full-primary at 92% opacity reads as
          // "navy bubble" without going stark on the warm background.
          color: context.hc.primary.withValues(alpha: 0.92),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(4),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(message.body, style: textStyle),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({
    required this.message,
    required this.streamingBodyStream,
    required this.isStreaming,
    required this.textStyle,
    this.onRetry,
    this.onPendingDecision,
  });

  final Message message;
  final Stream<String>? streamingBodyStream;
  final bool isStreaming;
  final TextStyle? textStyle;

  /// Hook to re-send the last user turn; rendered as an inline "Try again"
  /// row only when this is a finalised, errored bubble and a retry is
  /// currently allowed.
  final VoidCallback? onRetry;

  /// Resolve a pending destructive-action confirm card (run / keep).
  final void Function(String citation, {required bool confirmed})?
      onPendingDecision;

  @override
  Widget build(BuildContext context) {
    // The caregiver-facing text — `[action:…]` tags stripped, a raw
    // `[chat error: …]` trailer swapped for the friendly line. The raw
    // `message.body` is kept ONLY for failed-turn detection (showRetry)
    // below; it is never rendered.
    final String shownBody = ChatService.displayBody(message.body);

    final Widget body;
    if (isStreaming && shownBody.isEmpty) {
      // The reply has started (an empty assistant turn is on screen) but no
      // token has landed yet — show "Coach is thinking…" in place of a blank
      // bubble so the wait reads as activity, not a stall.
      body = const _TypingIndicator();
    } else if (isStreaming) {
      body = CaptionFade(
        key: ChatScreen.streamingBubbleKey,
        text: shownBody,
        stream: streamingBodyStream,
        style: textStyle,
      );
    } else {
      // Finalised message — render through MessageBody so any
      // `[card:<id>]` citation markers the assistant emitted resolve to
      // their salmon library-card chips (Phase 11.5).
      body = MessageBody(
        body: shownBody,
        style: textStyle,
      );
    }

    // A finalised bubble that carries the `[chat error: …]` sentinel is a
    // failed turn — surface an inline "Try again" under the body so the
    // caregiver can resend with one tap (#19). Suppressed while streaming
    // and while a retry is in flight (onRetry null). Detection runs on the
    // RAW body (the sentinel is stripped from `shownBody`).
    final bool showRetry =
        !isStreaming && onRetry != null && chatBodyHasError(message.body);

    return Semantics(
      label: 'Coach said: $shownBody',
      child: Container(
        key: ChatScreen.messageBubbleKey(message.id),
        decoration: BoxDecoration(
          color: context.hc.surfaceWarm,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(18),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            body,
            // Pending destructive actions (delete / cancel) the coach
            // proposed: each renders a confirm card and runs ONLY on an
            // explicit "Confirm" tap. Suppressed mid-stream (citations
            // land at finalisation).
            if (!isStreaming)
              for (final String citation in message.citations)
                if (ChatService.isPendingActionCitation(citation)) ...<Widget>[
                  const SizedBox(height: 10),
                  _PendingActionCard(
                    citation: citation,
                    onDecision: onPendingDecision,
                  ),
                ],
            if (showRetry) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Semantics(
                  button: true,
                  label: 'Try again. Re-send your last message to the coach.',
                  child: TextButton.icon(
                    key: ChatScreen.retryKey,
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      foregroundColor: context.hc.cta,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Try again'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// In-thread confirm card for a destructive action the coach proposed
/// (delete a medication, cancel an appointment, delete a task). The
/// write happens ONLY on the Confirm tap — never from the model reply
/// alone — so neither a typed request, a voice intent, nor injected
/// content in synced data can silently remove the caregiver's records.
class _PendingActionCard extends StatelessWidget {
  const _PendingActionCard({
    required this.citation,
    required this.onDecision,
  });

  final String citation;
  final void Function(String citation, {required bool confirmed})? onDecision;

  @override
  Widget build(BuildContext context) {
    final String question = ChatService.describePendingAction(citation) ??
        'Make this change?';
    return Container(
      key: ChatScreen.pendingActionCardKey(citation),
      decoration: BoxDecoration(
        color: context.hc.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hc.cta, width: 1.2),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.warning_amber_rounded,
                  size: 18, color: context.hc.cta),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  question,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: context.hc.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                key: ChatScreen.pendingActionDeclineKey(citation),
                onPressed: onDecision == null
                    ? null
                    : () => onDecision!(citation, confirmed: false),
                child: const Text('Keep it'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                key: ChatScreen.pendingActionConfirmKey(citation),
                style: FilledButton.styleFrom(
                  backgroundColor: context.hc.cta,
                  foregroundColor: Colors.white,
                ),
                onPressed: onDecision == null
                    ? null
                    : () => onDecision!(citation, confirmed: true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Input row pinned to the bottom of the screen — multiline text field
/// + circular salmon send button (BUILD_SPEC.md §3.1 `cta` token /
/// TASKS.md Phase 11.4 "send button salmon CTA"). The send button
/// dims itself out while a reply is in flight so a second tap can't
/// kick off a parallel stream and clobber the in-flight assistant
/// message's id.
class _Composer extends ConsumerStatefulWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  /// True while a spoken phrase is being captured for the composer field.
  /// Swaps the mic glyph for a progress ring + disables the button so a
  /// second tap can't start an overlapping capture (mirrors [VoiceButton]).
  bool _listening = false;

  /// Capture one spoken phrase through the shared [voiceCaptureProvider]
  /// seam and drop the transcript into the message field — the caregiver
  /// can then edit it or hit send (#fb_1780959784045575). Reuses the same
  /// capture impl + permission handling as the Home Add-sheet mic, so no
  /// new speech pipeline is introduced. A blank/aborted capture is a
  /// silent no-op; a denied mic surfaces the standard snackbar.
  /// Bumped on every capture start AND on send. A capture's partial/final
  /// writes only land while they still own the current generation — so a Send
  /// fired mid-dictation (which clears the field) is never undone by a trailing
  /// recognizer callback writing the just-sent text back (fb_1781129156352504).
  int _captureGen = 0;

  Future<void> _captureIntoField() async {
    if (_listening) return;
    final int gen = ++_captureGen;
    setState(() => _listening = true);
    // Anchor to whatever's already typed so a mid-compose capture APPENDS
    // rather than clobbers; the live partials + the final transcript build
    // on this prefix.
    final String base = widget.controller.text;
    final String prefix = base.isEmpty ? '' : '${base.trimRight()} ';
    void fill(String words) {
      // A send (or a newer capture) superseded us — don't write into a field
      // the caregiver already sent/cleared.
      if (gen != _captureGen) return;
      final String joined = '$prefix$words';
      widget.controller
        ..text = joined
        ..selection = TextSelection.collapsed(offset: joined.length);
    }

    try {
      final String? transcript =
          await ref.read(voiceCaptureProvider).capture(
        // Stream the words into the field as they're recognized, so the
        // caregiver SEES it working word-for-word (fb_1781034095668808).
        onPartial: (String partial) {
          if (mounted && partial.trim().isNotEmpty) fill(partial);
        },
      );
      // Superseded by a send/new capture while we awaited the final transcript
      // → leave the field exactly as the send left it.
      if (!mounted || gen != _captureGen) return;
      final String text = transcript?.trim() ?? '';
      if (text.isEmpty) {
        // Nothing usable — restore the pre-capture text (drop any partials).
        widget.controller
          ..text = base
          ..selection = TextSelection.collapsed(offset: base.length);
        return;
      }
      fill(text);
    } on VoiceCapturePermissionDeniedException {
      if (!mounted || gen != _captureGen) return;
      widget.controller
        ..text = base
        ..selection = TextSelection.collapsed(offset: base.length);
      showVoiceCapturePermissionDeniedSnackBar(context);
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  /// Send handler — invalidate any in-flight dictation (so a late recognizer
  /// callback can't re-fill the field after we've sent), then hand off to the
  /// parent's send.
  void _handleSend() {
    _captureGen++;
    widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool sending = widget.sending;
    return Container(
      decoration: BoxDecoration(
        color: context.hc.background,
        border: Border(
          top: BorderSide(
            color: context.hc.surfaceWarm,
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: context.hc.surfaceWarm,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                key: ChatScreen.inputFieldKey,
                controller: widget.controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                style: textTheme.bodyLarge?.copyWith(
                  color: context.hc.text,
                ),
                decoration: InputDecoration(
                  hintText: 'Ask the coach...',
                  hintStyle: textTheme.bodyLarge?.copyWith(
                    color: context.hc.primarySoft,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                ),
                inputFormatters: <TextInputFormatter>[
                  LengthLimitingTextInputFormatter(2000),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Composer mic — capture a spoken phrase into the field
          // (#fb_1780959784045575 / fb_1781034095668808). Moved to the RIGHT
          // beside Send and made a filled, brand-coloured circle so it's easy
          // to spot; while listening the whole button turns salmon with a
          // ring so it clearly reads as "recording". The transcript streams
          // in word-for-word via [_captureIntoField]'s onPartial. "Listening…"
          // reads on the semantics label without naming the speech tech.
          Semantics(
            button: true,
            enabled: !_listening,
            label: _listening
                ? 'Listening. Speak your message.'
                : 'Speak your message.',
            child: Material(
              color: _listening ? context.hc.cta : context.hc.surfaceWarm,
              shape: const CircleBorder(),
              child: InkWell(
                key: ChatScreen.composerMicKey,
                customBorder: const CircleBorder(),
                onTap: _listening ? null : _captureIntoField,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _listening
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : Icon(Icons.mic, color: context.hc.cta, size: 24),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            enabled: !sending,
            label: 'Send message to the coach.',
            child: Material(
              color: sending
                  ? context.hc.cta.withValues(alpha: 0.5)
                  : context.hc.cta,
              shape: const CircleBorder(),
              child: InkWell(
                key: ChatScreen.sendButtonKey,
                customBorder: const CircleBorder(),
                onTap: sending ? null : _handleSend,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(
                    Icons.send,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

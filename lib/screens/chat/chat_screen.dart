import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat.dart';
import '../../services/chat_repository.dart';
import '../../services/chat_service.dart';
import '../../theme.dart';
import '../../widgets/caption_fade.dart';
import '../../widgets/message_body.dart';
import '../../widgets/path_header.dart';
import 'conversation_list_screen.dart';

/// Multi-turn chat with the dementia-care coach (TASKS.md Phase 11.4).
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

  /// Stable per-bubble key so widget + golden tests can find a specific
  /// message without depending on its visible body.
  static Key messageBubbleKey(String messageId) =>
      Key('chat-screen-bubble-$messageId');

  /// Marks the currently-streaming assistant bubble so tests can assert
  /// the in-flight presentation (CaptionFade + soft "typing" affordance)
  /// independently of the message id.
  static const Key streamingBubbleKey = Key('chat-screen-streaming-bubble');

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
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

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    final ChatRepository repo = ref.read(chatRepositoryProvider);
    final List<Message> initial = await repo.loadMessages(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _hydrated = true;
      for (final Message m in initial) {
        if (!_messages.containsKey(m.id)) _order.add(m.id);
        _messages[m.id] = m;
      }
    });
    _scrollToBottom();
  }

  @override
  void dispose() {
    _sendSubscription?.cancel();
    _streamingBodyController?.close();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final String text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    setState(() => _sending = true);

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

    await done.future;
    if (!mounted) return;
    setState(() {
      _sending = false;
      _streamingAssistantId = null;
    });
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
        _streamingBodyController?.add(m.body);
      } else if (m.role == MessageRole.assistant && m.streamingDone) {
        // Final body lands — push one last emission so CaptionFade fades
        // the trailing tokens before the bubble swaps to the static
        // MessageBody (which renders citation chips).
        _streamingBodyController?.add(m.body);
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

    return Scaffold(
      backgroundColor: careblazersColors.background,
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
              child: _hydrated && ordered.isEmpty
                  ? const _EmptyHint()
                  : ListView.builder(
                      key: ChatScreen.listKey,
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                      itemCount: ordered.length,
                      itemBuilder: (BuildContext context, int index) {
                        final Message m = ordered[index];
                        final bool isStreaming = m.id == _streamingAssistantId;
                        return _MessageRow(
                          message: m,
                          streamingBodyStream: isStreaming
                              ? _streamingBodyController?.stream
                              : null,
                          isStreaming: isStreaming,
                        );
                      },
                    ),
            ),
            if (widget.composerPrefix != null) widget.composerPrefix!,
            _Composer(
              controller: _input,
              sending: _sending,
              onSend: _send,
            ),
          ],
        ),
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
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 12),
          Text(
            'Ask anything.',
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            "What is sundowning? Why is she accusing me? What can I "
            "say when he asks for his mom?",
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.primarySoft,
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
class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.streamingBodyStream,
    required this.isStreaming,
  });

  final Message message;
  final Stream<String>? streamingBodyStream;
  final bool isStreaming;

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
        textStyle: textTheme.bodyLarge?.copyWith(
          color: careblazersColors.primary,
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
          child: bubble,
        ),
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
          color: careblazersColors.primary.withValues(alpha: 0.92),
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
  });

  final Message message;
  final Stream<String>? streamingBodyStream;
  final bool isStreaming;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (isStreaming) {
      body = CaptionFade(
        key: ChatScreen.streamingBubbleKey,
        text: message.body,
        stream: streamingBodyStream,
        style: textStyle,
      );
    } else {
      // Finalised message — render through MessageBody so any
      // `[card:<id>]` citation markers the assistant emitted resolve to
      // their salmon library-card chips (Phase 11.5).
      body = MessageBody(
        body: message.body,
        style: textStyle,
      );
    }

    return Semantics(
      label: 'Coach said: ${message.body}',
      child: Container(
        key: ChatScreen.messageBubbleKey(message.id),
        decoration: BoxDecoration(
          color: careblazersColors.surfaceWarm,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(18),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: body,
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
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: careblazersColors.background,
        border: Border(
          top: BorderSide(
            color: careblazersColors.surfaceWarm,
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
                color: careblazersColors.surfaceWarm,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                key: ChatScreen.inputFieldKey,
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
                ),
                decoration: InputDecoration(
                  hintText: 'Ask the coach...',
                  hintStyle: textTheme.bodyLarge?.copyWith(
                    color: careblazersColors.primarySoft,
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
          Semantics(
            button: true,
            enabled: !sending,
            label: 'Send message to the coach.',
            child: Material(
              color: sending
                  ? careblazersColors.cta.withValues(alpha: 0.5)
                  : careblazersColors.cta,
              shape: const CircleBorder(),
              child: InkWell(
                key: ChatScreen.sendButtonKey,
                customBorder: const CircleBorder(),
                onTap: sending ? null : onSend,
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

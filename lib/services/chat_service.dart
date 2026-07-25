import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/chat.dart';
import '../providers/forum_jwt_provider.dart' show forumSessionManagerProvider;
import '../providers/llm_provider.dart'
    show buildShimDio, claudeShimEndpoint, shimAuthHeaders, useFakeLLMEngine;
import '../seed/chat_system_prompt.dart';
import 'api_chat_backend.dart';
import 'chat_actions.dart';
import 'chat_context_builder.dart';
import 'chat_repository.dart';
import 'crisis_keywords.dart' show messageTriggersCrisis;
import 'feedback_service.dart' show feedbackUiEnabled;
import 'forum_api_client.dart' show forumApiBaseUrl, forumBackendConfigured;

part 'chat_service.g.dart';

/// One past turn the model can see when it composes the next reply
/// (TASKS.md Phase 11.3). [ChatService] flattens
/// [ChatRepository.loadMessages] into this minimal shape — the model
/// doesn't need the persistence id, the citations list, or the
/// streaming-done flag, only role + body.
class ChatTurn {
  const ChatTurn({required this.role, required this.content});

  final MessageRole role;
  final String content;
}

/// One event from a streaming chat backend (TASKS.md Phase 11.3).
///
/// The stream emits zero or more [ChatDeltaText] events as the assistant
/// generates text, then terminates with either a natural close (the
/// implicit "done") or a [ChatDeltaError] surfaced to the caller.
/// [ChatService] folds [ChatDeltaText.text] into the in-flight
/// [Message.body]; [ChatDeltaError] marks the assistant message
/// `streamingDone: true` with whatever was accumulated so the failed
/// turn is still visible in the thread instead of vanishing.
sealed class ChatDelta {
  const ChatDelta();
}

/// A text fragment to append to the assistant's accumulating reply.
final class ChatDeltaText extends ChatDelta {
  const ChatDeltaText(this.text);

  final String text;
}

/// Terminates the stream with a transport, shim, or parse failure.
final class ChatDeltaError extends ChatDelta {
  const ChatDeltaError(this.message);

  final String message;
}

/// Prefix [ChatService] stamps onto the assistant bubble's body when a
/// reply stream fails (`[chat error: <message>]`). Exposed so the chat
/// screen can detect a failed turn and surface a retry affordance without
/// re-deriving the private trailer format. The closing `]` is appended by
/// the service; this is just the opening sentinel callers match on.
///
/// This sentinel — and the raw transport detail it wraps (a `DioException`,
/// a shim port, a parse failure) — is an INTERNAL marker. It stays in the
/// stored body so [chatBodyHasError] can light up the inline retry, but it
/// must NEVER reach the caregiver verbatim: every display path runs the
/// body through [ChatService.displayBody] first, which swaps the whole
/// trailer for [chatFriendlyErrorMessage].
const String chatErrorMarkerPrefix = '[chat error:';

/// Caregiver-facing copy substituted for the raw `[chat error: …]`
/// trailer at render time. Brand-voiced, mentions no transport/internal
/// detail (no "AI", no shim, no exception class) — the coach is simply
/// unreachable for the moment. Used by [ChatService.displayBody].
const String chatFriendlyErrorMessage =
    "Couldn't reach the coach just now. Try again in a moment.";

/// True when [body] carries the failed-turn sentinel — i.e. the reply
/// stream errored and [ChatService] folded `[chat error: …]` into the
/// assistant message. Drives the chat screen's inline "Try again" action.
bool chatBodyHasError(String body) => body.contains(chatErrorMarkerPrefix);

/// Honest failure line appended to a reply when an action the coach's prose
/// implied it performed actually THREW (alpha bug: the bubble said "logged
/// it" while nothing saved). Brand-voiced, no vendor/transport detail; tells
/// the caregiver plainly so they can retry or use the screen directly.
const String chatActionFailedMessage =
    "I couldn't save that just now — please try again, or make the change "
    'from its screen.';

/// Streaming-chat backend (TASKS.md Phase 11.3, BUILD_SPEC.md §6
/// "every backend is an interface").
///
/// Two seams sit behind this contract: the real
/// [ClaudeShimChatBackend] (POSTs the dialogue to
/// `tools/claude_shim.py` on `localhost:8765`) and any test-side
/// scripted backend the unit tests inject. The service never imports a
/// concrete impl directly; it goes through [chatLLMBackendProvider].
abstract class ChatLLMBackend {
  /// Stream the assistant's next reply given [systemPrompt] and the
  /// full conversation [history] (oldest-first; the final entry is the
  /// latest user message). Implementations yield zero-or-more
  /// [ChatDeltaText]s and either close cleanly (success) or yield a
  /// final [ChatDeltaError] (failure). Once an error is yielded the
  /// stream MUST close.
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  });
}

/// Real, shim-backed [ChatLLMBackend] (TASKS.md Phase 11.3).
///
/// POSTs `{system, user}` to [claudeShimEndpoint] — the shim only
/// accepts a single `user` payload (BUILD_SPEC.md §8), so prior turns
/// are formatted into the [user] string by [formatHistory]. Consumes
/// the SSE stream the shim forwards from `claude --print
/// --output-format stream-json`, extracts text from each `assistant`
/// event, and yields one [ChatDeltaText] per non-empty fragment. On
/// transport failure or an `{"error": ...}` event the stream
/// terminates with [ChatDeltaError].
class ClaudeShimChatBackend implements ChatLLMBackend {
  const ClaudeShimChatBackend({
    Dio? dio,
    this.endpoint = claudeShimEndpoint,
  }) : _injectedDio = dio;

  /// Injected for tests — production constructs a fresh [Dio] per
  /// request so the riverpod provider can stay `const`.
  final Dio? _injectedDio;

  /// Override only for integration tests that pin a different port.
  final String endpoint;

  /// Render [history] into the single `user` string the shim accepts.
  ///
  /// The shim's `claude --print` invocation takes one positional user
  /// argument, so multi-turn context has to be embedded inline. The
  /// format prefixes each prior turn with a role label and then names
  /// the latest message explicitly so the model knows which one to
  /// answer. Static + visible for the unit test that pins the shape.
  static String formatHistory(List<ChatTurn> history) {
    if (history.isEmpty) {
      return '';
    }
    final StringBuffer sb = StringBuffer();
    if (history.length > 1) {
      sb.writeln('[Conversation so far]');
      for (int i = 0; i < history.length - 1; i++) {
        final ChatTurn turn = history[i];
        final String label = turn.role == MessageRole.user
            ? 'Caregiver'
            : 'Coach';
        // Indent continuation lines so multi-line content can never put
        // "Coach:" / "Caregiver:" at column 0 and spoof a turn boundary
        // (role labels are only ever at the start of an unindented line).
        final String content = turn.content.replaceAll('\n', '\n  ');
        sb.writeln('$label: $content');
      }
      sb.writeln();
    }
    sb.writeln('[Latest caregiver message]');
    sb.write(history.last.content);
    return sb.toString();
  }

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    final Dio dio = _injectedDio ?? buildShimDio();
    final String userMessage = formatHistory(history);

    Response<ResponseBody> response;
    try {
      response = await dio.post<ResponseBody>(
        endpoint,
        data: <String, dynamic>{
          'system': systemPrompt,
          'user': userMessage,
          // Opt into token streaming — the shim adds --include-partial-messages
          // so the reply streams in as it generates instead of landing all at
          // once when it's finished (the recap leaves this off).
          'partial': true,
        },
        options: Options(
          responseType: ResponseType.stream,
          contentType: Headers.jsonContentType,
          headers: shimAuthHeaders(),
        ),
      );
    } catch (e) {
      yield ChatDeltaError('shim request failed: $e');
      return;
    }

    final ResponseBody? body = response.data;
    if (body == null) {
      yield const ChatDeltaError('shim returned an empty response body');
      return;
    }

    // Buffer raw bytes (not decoded text) so a multi-byte UTF-8
    // sequence split across two `Uint8List` reads doesn't get mangled
    // into a replacement char — the coach voice includes em-dashes
    // and smart quotes the model echoes back.
    final List<int> rawBuffer = <int>[];
    // Tracks whether any incremental token chunk has streamed. Once one
    // has, the terminal complete `assistant` message is a duplicate of what
    // we already emitted and is skipped. A one-element list so the static
    // block helper can mutate it across calls.
    final List<bool> sawPartial = <bool>[false];
    try {
      await for (final Uint8List bytes in body.stream) {
        rawBuffer.addAll(bytes);
        while (true) {
          final int sep = _indexOfDoubleNewline(rawBuffer);
          if (sep == -1) break;
          final List<int> eventBytes = rawBuffer.sublist(0, sep);
          rawBuffer.removeRange(0, sep + _eventBoundaryLength(rawBuffer, sep));
          final String event = utf8.decode(eventBytes);
          for (final ChatDelta d in _deltasFromBlock(event, sawPartial)) {
            yield d;
            if (d is ChatDeltaError) return;
          }
        }
      }
      // Shim's final flush may omit the closing `\n\n`; drain any
      // trailing partial event the same way.
      if (rawBuffer.isNotEmpty) {
        final String trailing = utf8.decode(rawBuffer);
        rawBuffer.clear();
        for (final ChatDelta d in _deltasFromBlock(trailing, sawPartial)) {
          yield d;
          if (d is ChatDeltaError) return;
        }
      }
    } catch (e) {
      yield ChatDeltaError('stream read failed: $e');
    }
  }

  /// Parse one `\n\n`-delimited block of `data:` lines into zero or more
  /// deltas. Incremental `text_delta` chunks (when the shim streams with
  /// --include-partial-messages) are appended as they arrive and flip
  /// [sawPartial]; the terminal complete `assistant` message is emitted
  /// ONLY when no partials streamed (non-streaming mode) — otherwise it's
  /// a duplicate of the already-streamed text and is dropped. No-op events
  /// (init line, `[DONE]`, untyped payloads) yield nothing.
  static Iterable<ChatDelta> _deltasFromBlock(
      String block, List<bool> sawPartial) sync* {
    for (final String rawLine in block.split('\n')) {
      // CRLF tolerance: strip a trailing \r left by \r\n events.
      final String line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      if (!line.startsWith('data:')) continue;
      final String payload = line.substring(5).startsWith(' ')
          ? line.substring(6)
          : line.substring(5);
      if (payload == '[DONE]') continue;
      final _ChatEventPayload parsed = _parseEvent(payload);
      if (parsed.error != null) {
        yield ChatDeltaError(parsed.error!);
        continue;
      }
      final String? text = parsed.text;
      if (text == null || text.isEmpty) continue;
      if (parsed.isPartial) {
        sawPartial[0] = true;
        yield ChatDeltaText(text);
      } else if (!sawPartial[0]) {
        // Non-streaming mode: the complete message is the whole reply.
        yield ChatDeltaText(text);
      }
      // else: partials already delivered this text — drop the echo.
    }
  }

  static int _indexOfDoubleNewline(List<int> bytes) {
    for (int i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] != 0x0A) continue;
      if (bytes[i + 1] == 0x0A) return i;
      if (i < bytes.length - 2 &&
          bytes[i + 1] == 0x0D &&
          bytes[i + 2] == 0x0A) {
        return i;
      }
    }
    return -1;
  }

  /// Length of the separator found at [sep] by [_indexOfDoubleNewline]
  /// (2 for `\n\n`, 3 for `\n\r\n` — i.e. CRLF-normalised events).
  static int _eventBoundaryLength(List<int> bytes, int sep) =>
      bytes[sep + 1] == 0x0A ? 2 : 3;

  /// Extract a text delta (or error) from one SSE event payload.
  /// Mirrors [ClaudeCLIProvider]'s `assistant`-event handler — the
  /// shim forwards the same `stream-json` shape for both endpoints.
  static _ChatEventPayload _parseEvent(String payload) {
    final dynamic obj;
    try {
      obj = json.decode(payload);
    } on FormatException {
      return const _ChatEventPayload();
    }
    if (obj is! Map<String, dynamic>) return const _ChatEventPayload();
    if (obj['error'] is String) {
      return _ChatEventPayload(error: obj['error'] as String);
    }
    final String? type = obj['type'] as String?;
    // Token-streaming chunk (shim ran with --include-partial-messages):
    // {"type":"stream_event","event":{"type":"content_block_delta",
    //   "delta":{"type":"text_delta","text":"..."}}}. Each is an incremental
    // fragment to append — marked isPartial so the loop can skip the
    // duplicate complete `assistant` echo that follows.
    if (type == 'stream_event') {
      final dynamic ev = obj['event'];
      if (ev is Map<String, dynamic> &&
          ev['type'] == 'content_block_delta') {
        final dynamic delta = ev['delta'];
        if (delta is Map<String, dynamic> && delta['type'] == 'text_delta') {
          final dynamic text = delta['text'];
          if (text is String) {
            return _ChatEventPayload(text: text, isPartial: true);
          }
        }
      }
      return const _ChatEventPayload();
    }
    if (type == 'assistant') {
      final dynamic message = obj['message'];
      if (message is Map<String, dynamic>) {
        final dynamic content = message['content'];
        if (content is List) {
          final StringBuffer sb = StringBuffer();
          for (final dynamic block in content) {
            if (block is Map<String, dynamic> && block['type'] == 'text') {
              final dynamic text = block['text'];
              if (text is String) sb.write(text);
            }
          }
          return _ChatEventPayload(text: sb.toString());
        }
      }
    }
    return const _ChatEventPayload();
  }
}

class _ChatEventPayload {
  const _ChatEventPayload({this.text, this.error, this.isPartial = false});
  final String? text;
  final String? error;

  /// True for an incremental token chunk (a `text_delta`). False for a
  /// complete `assistant` message. Once any partial has streamed, the
  /// terminal complete message is a duplicate and must be skipped.
  final bool isPartial;
}

/// Mint a chat message id. Overridable so tests get deterministic ids
/// to assert against. Production stamps a millisecond timestamp + a
/// 32-bit random suffix.
typedef ChatIdFactory = String Function();

String _defaultChatIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'chat-$ms-$rand';
}

/// Produces a short thread title from its opening [turns], or null when
/// none could be made (backend error, empty output). Injected into
/// [ChatService.titleGenerator]; production wires [generateChatTitle].
typedef ChatTitleGenerator = Future<String?> Function(List<ChatTurn> turns);

/// System prompt for the one-shot title pass (fb_1781115614890041). Asks
/// for a tiny, plain label — no "AI"/coach framing leaks since the output
/// is just the thread's name. Kept deliberately terse so the model returns
/// a few words, not a sentence; [sanitizeChatTitle] hardens whatever comes
/// back (strips quotes/punctuation, caps the length at a word boundary).
const String chatTitleSystemPrompt =
    'You name a saved conversation for a family caregiver. Reply with ONLY '
    'a short, specific title of 2 to 5 words that captures what the caregiver '
    'is asking about. Title Case. No quotes, no punctuation, no emoji, no '
    'trailing period. Examples: Restless At Dinner, Refusing To Bathe, '
    'Asking The Same Question.';

/// Clean a raw model-produced title into a tile-ready label, or null when
/// nothing usable remains. Takes the first line, strips wrapping quotes and
/// stray trailing punctuation, collapses whitespace, and caps the length at
/// a word boundary (~40 chars) so it never overflows the tile.
String? sanitizeChatTitle(String? raw) {
  if (raw == null) return null;
  String t = raw.trim();
  if (t.isEmpty) return null;
  // First non-empty line only — the model occasionally adds a preamble.
  t = t
      .split('\n')
      .map((String l) => l.trim())
      .firstWhere((String l) => l.isNotEmpty, orElse: () => '');
  if (t.isEmpty) return null;
  // Strip a matched pair of wrapping quotes.
  if (t.length >= 2 &&
      ((t.startsWith('"') && t.endsWith('"')) ||
          (t.startsWith("'") && t.endsWith("'")))) {
    t = t.substring(1, t.length - 1).trim();
  }
  // Drop stray leading/trailing punctuation + collapse inner whitespace.
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceAll(RegExp(r'^[\s\-–—:"' "'" r'.]+|[\s\-–—:"' "'" r'.]+$'), '');
  if (t.isEmpty) return null;
  if (t.length <= 40) return t;
  final String cut = t.substring(0, 40);
  final int lastSpace = cut.lastIndexOf(' ');
  return (lastSpace > 20 ? cut.substring(0, lastSpace) : cut).trim();
}

/// Production [ChatTitleGenerator]: one non-streaming pass over [backend]
/// with [chatTitleSystemPrompt] to name a thread from its opening [turns].
/// Returns the raw title text (the caller sanitizes) or null on any backend
/// error so auto-titling silently degrades to the derived succinct name.
Future<String?> generateChatTitle(
  ChatLLMBackend backend,
  List<ChatTurn> turns,
) async {
  final StringBuffer buffer = StringBuffer();
  await for (final ChatDelta delta in backend.streamReply(
    systemPrompt: chatTitleSystemPrompt,
    history: turns,
  )) {
    switch (delta) {
      case ChatDeltaText(:final String text):
        buffer.write(text);
      case ChatDeltaError():
        return null;
    }
  }
  final String out = buffer.toString().trim();
  return out.isEmpty ? null : out;
}

/// Default [ChatService.contextSnapshot] — no data injected. Keeps the
/// service unit-testable (the prompt equals [chatSystemPrompt] unchanged)
/// and chat-only surfaces wiring-free.
Future<String> _emptyContextSnapshot() async => '';

/// Pattern for `[action:<name> key="value" …]` tool-call markers in a
/// finished assistant reply.
///
/// Quote-aware on purpose: values are matched as full `"…"` strings
/// (with `\"` escapes) or bare tokens, so a quoted value containing a
/// literal `]` (e.g. `title="Pick up [urgent] refill"`) no longer
/// truncates the tag mid-parse and garbles the write.
///
/// Group 1: the action name (e.g. `log_journal`).
/// Group 2: the raw `key="value" …` tail to feed [_parseActionArgs].
final RegExp _actionPattern = RegExp(
  r'\[action:([a-z_]+)((?:\s+[a-z_]+\s*=\s*(?:"(?:[^"\\]|\\.)*"|[^\s\]"]+))+)\s*\]',
);

/// Action-execution result the orchestrator stamps into the assistant
/// message's [Message.citations] list. Carries the citation a chip
/// renderer can deep-link from.
class _ActionResult {
  const _ActionResult({required this.citation});
  final String citation;
}

/// Outcome of one action pass over a finished reply: the citations of
/// executed (instant) actions, the RAW markers of mutating actions parked
/// for the caregiver's explicit in-app confirmation, and — when an executor
/// did NOT perform its write — the reasons, so the caller can correct prose
/// that already claimed success.
class _ActionPass {
  const _ActionPass({
    this.results = const <_ActionResult>[],
    this.pendingMarkers = const <String>[],
    this.hadFailure = false,
    this.failureNotices = const <String>[],
    this.notices = const <String>[],
  });

  final List<_ActionResult> results;
  final List<String> pendingMarkers;

  /// True when an instant (non-confirmed) executor threw OR reported that it
  /// did nothing. The confirm-card flow reports its own failures through
  /// [ChatService.confirmPendingAction], so only instant executions feed this.
  final bool hadFailure;

  /// Caregiver-facing reasons from executors that DIDN'T perform their write
  /// (e.g. "what dose is it?"). Preferred over the generic failure line — a
  /// specific reason lets the caregiver fix it in one reply. Empty when the
  /// only failure was a thrown exception (no reason to give).
  final List<String> failureNotices;

  /// Disclosures from executors that DID perform, but not exactly as asked —
  /// a dose window we had to create (with a time we assumed), a name that
  /// matched nothing. Appended so a partial success can't read as a complete
  /// one.
  final List<String> notices;

  /// The line(s) to append to the reply so its prose can't claim more than
  /// actually happened — a write that failed, or one that only partly matched
  /// what was asked. Null when there is nothing to disclose.
  String? get failureTrailer {
    final List<String> lines = <String>[
      if (hadFailure)
        ...(failureNotices.isEmpty
            ? <String>[chatActionFailedMessage]
            : failureNotices),
      ...notices,
    ];
    return lines.isEmpty ? null : lines.join('\n\n');
  }

  /// Message citations for this pass: executed-action citations first,
  /// then one `pending_action:` citation per unconfirmed marker.
  List<String> toCitations() => <String>[
        for (final _ActionResult r in results) r.citation,
        for (final String marker in pendingMarkers)
          '${ChatService.pendingActionCitationPrefix}$marker',
      ];
}

/// Result of [ChatService.routeVoiceIntent] — the hands-free center mic
/// either performed an action (no thread) or opened a conversation.
sealed class VoiceIntentOutcome {
  const VoiceIntentOutcome();
}

/// The spoken request was a clear command the coach carried out. [summary]
/// is its one-line confirmation, shown in a transient overlay; no chat
/// thread is created and the caregiver stays where they were.
class VoiceIntentAction extends VoiceIntentOutcome {
  const VoiceIntentAction({required this.summary});
  final String summary;
}

/// The spoken request was a conversation. The turn + the coach's reply are
/// already persisted under [conversationId]; the UI opens `/chat/<id>`.
class VoiceIntentChat extends VoiceIntentOutcome {
  const VoiceIntentChat({
    required this.conversationId,
    this.spokenReply = '',
  });
  final String conversationId;

  /// The reply body, already stripped of action markers — what the mic flow
  /// reads back aloud. Carried on the outcome so the UI speaks the SAME text
  /// it persisted, without a second model call or a re-read of the thread.
  final String spokenReply;
}

/// Multi-turn caregiving chat orchestrator (TASKS.md Phase 11.3).
///
/// Wraps a [ChatLLMBackend] (defaults to [ClaudeShimChatBackend], the
/// shim-backed real impl) and a [ChatRepository]. Per-message flow:
///
///   1. Append the caregiver's [userText] to the repository as a
///      `MessageRole.user` row.
///   2. Insert an empty assistant placeholder with
///      `streamingDone: false`; the chat screen renders this as the
///      "typing..." in-flight bubble.
///   3. Stream deltas from [ChatLLMBackend.streamReply]; on each
///      [ChatDeltaText] append the fragment to the assistant's [body]
///      and re-persist via [ChatRepository.appendMessage]
///      (`insertOnConflictUpdate` overwrites the row in place).
///   4. On stream-close, execute any `[action:<name> …]` tool markers in
///      the final body and record their result references in
///      [Message.citations] (deduplicated, first-seen order, e.g.
///      `journal:<id>`), strip the markers from the shown body, and flip
///      `streamingDone: true`.
///   5. On [ChatDeltaError], mark the partial assistant message done
///      and surface the error message to the stream subscriber.
///
/// The stream yields every snapshot the repository writes — both the
/// user turn (once) and the assistant message (once per delta + the
/// final done update). The chat screen (Phase 11.4) consumes this
/// stream to update its message list reactively without re-querying
/// drift between deltas.
class ChatService {
  ChatService({
    required this.repository,
    required this.backend,
    Map<String, ChatActionExecutor>? actions,
    Future<String> Function()? contextSnapshot,
    ChatIdFactory? idFactory,
    DateTime Function()? clock,
    this.titleGenerator,
  })  : actions = actions ?? const <String, ChatActionExecutor>{},
        contextSnapshot = contextSnapshot ?? _emptyContextSnapshot,
        idFactory = idFactory ?? _defaultChatIdFactory,
        clock = clock ?? DateTime.now;

  final ChatRepository repository;
  final ChatLLMBackend backend;

  /// Fetches a compact, plain-text snapshot of the caregiver's CURRENT data
  /// (loved one, medications, dose windows, upcoming appointments, routines)
  /// to append to the system prompt so the coach can READ what's already in
  /// the app — answering "what meds is she on?", "what are my windows
  /// called?". Called FRESH every turn so the snapshot reflects a write the
  /// coach itself just made. Defaults to a no-op (empty string) so unit
  /// tests and chat-only surfaces don't have to wire the repositories;
  /// production injects [gatherChatContext] via [chatServiceProvider]. A
  /// failure here must never fail the turn — [sendMessage] swallows it.
  final Future<String> Function() contextSnapshot;

  /// Tool registry — the `[action:<name> …]` markers the assistant may
  /// emit, each mapped to an executor that performs the write and returns
  /// an optional citation. Empty for chat-only surfaces (e.g. the
  /// onboarding tour) — then markers are stripped from the displayed text
  /// but nothing is written. Production wires the full CRUD set via
  /// [buildChatActions] in [chatServiceProvider].
  final Map<String, ChatActionExecutor> actions;

  final ChatIdFactory idFactory;
  final DateTime Function() clock;

  /// Produces a short display title from a thread's opening turns, or null
  /// when no title could be made. Fired ONCE — fire-and-forget after the
  /// first assistant reply lands — so the conversation list shows a real
  /// coach-written name instead of a raw truncation of the first message
  /// (fb_1781115614890041). Null disables auto-titling: unit + widget tests
  /// leave it unset so a `sendMessage` never makes a second backend call
  /// (callCount/idFactory assertions stay exact). Production wires
  /// [generateChatTitle] via [chatServiceProvider].
  final ChatTitleGenerator? titleGenerator;

  /// Test-only handle on the fire-and-forget auto-title attempt for the
  /// most recent [sendMessage]. Null until an attempt is launched (so a
  /// test can assert "auto-title was NOT attempted" by checking it stayed
  /// null), then completes when the attempt finishes — letting tests
  /// await a deterministic signal instead of a wall-clock sleep.
  @visibleForTesting
  Future<void>? debugAutoTitleSettled;

  /// Send [userText] in the existing [conversationId] thread and stream
  /// the assistant's reply. Yields [Message] snapshots as each repo
  /// write lands — first the user turn, then the assistant message
  /// once per text delta plus a final done write.
  Stream<Message> sendMessage({
    required String conversationId,
    required String userText,
  }) async* {
    final Message userMessage = Message(
      id: idFactory(),
      conversationId: conversationId,
      role: MessageRole.user,
      body: userText,
      citations: const <String>[],
      createdAt: clock(),
      streamingDone: true,
    );
    await repository.appendMessage(userMessage);
    yield userMessage;

    // Code-side crisis watchdog (does NOT depend on the model): scan the
    // caregiver's outgoing message and, on a vetted-keyword match, pin a
    // TRUSTED crisis-resources card into the thread ABOVE the coach's reply.
    // The card is a real assistant-role row carrying only the crisis
    // citation (no prose), so it renders even if the model reply never
    // lands. Done once per matching turn.
    if (messageTriggersCrisis(userText)) {
      final Message crisisCard = Message(
        id: idFactory(),
        conversationId: conversationId,
        role: MessageRole.assistant,
        body: '',
        citations: const <String>[crisisCardCitation],
        createdAt: clock(),
        streamingDone: true,
      );
      await repository.appendMessage(crisisCard);
      yield crisisCard;
    }

    // Constructed before loadMessages so the catch below always has an
    // assistant turn to convert into a visible error bubble — but only
    // APPENDED after the history read, so `history` is just the prior
    // turns + the user message, not an empty assistant.
    Message assistant = Message(
      id: idFactory(),
      conversationId: conversationId,
      role: MessageRole.assistant,
      body: '',
      citations: const <String>[],
      createdAt: clock(),
      streamingDone: false,
    );

    try {
      // The model sees every prior turn plus the just-appended user
      // message — loadMessages returns them in chronological order so
      // the latest entry is the one to reply to. The trusted crisis card
      // (an empty assistant row carrying only the crisis citation) is
      // dropped from the model's view — it's a UI pin, not a coach turn.
      final List<Message> history =
          await repository.loadMessages(conversationId);
      final List<ChatTurn> turns = history
          .where((Message m) => !_isCrisisCardMessage(m))
          .map((Message m) => ChatTurn(role: m.role, content: m.body))
          .toList(growable: false);
      // First exchange in a brand-new thread → history is just the
      // user turn we appended above. Used to fire the one-shot auto-title
      // once the reply lands.
      final bool isFirstTurn = turns.length == 1;

      await repository.appendMessage(assistant);
      yield assistant;

      // Pull a fresh read-only snapshot of the caregiver's current data and
      // append it under the prompt so the coach can SEE what's in the app
      // (alpha bug: it could write but not read). Fetched per turn so it
      // reflects a med/appointment the coach itself just added. A failure
      // here degrades to no snapshot — it must never sink the turn.
      String systemPrompt = chatSystemPrompt;
      try {
        final String snapshot = await contextSnapshot();
        if (snapshot.trim().isNotEmpty) {
          systemPrompt = '$chatSystemPrompt\n\n$snapshot';
        }
      } catch (_) {
        systemPrompt = chatSystemPrompt;
      }

      final StringBuffer buffer = StringBuffer();
      bool errored = false;

      await for (final ChatDelta delta in backend.streamReply(
        systemPrompt: systemPrompt,
        history: turns,
      )) {
        switch (delta) {
          case ChatDeltaText(:final String text):
            buffer.write(text);
            assistant = assistant.copyWith(body: buffer.toString());
            await repository.appendMessage(assistant);
            yield assistant;
          case ChatDeltaError(:final String message):
            errored = true;
            final String marker = '$chatErrorMarkerPrefix $message]';
            final String trailer =
                buffer.isEmpty ? marker : '$buffer\n\n$marker';
            assistant = assistant.copyWith(
              body: stripActionMarkers(trailer),
              citations: const <String>[],
              streamingDone: true,
            );
            await repository.appendMessage(assistant);
            yield assistant;
            return;
        }
      }

      if (errored) return;

      final String rawBody = buffer.toString();
      final _ActionPass actionPass = await _executeActions(rawBody, userText: userText);
      String cleanBody = stripActionMarkers(rawBody);
      // An instant executor threw — the prose likely claimed success, so
      // append an honest line rather than let the reply lie about the save.
      final String? trailer = actionPass.failureTrailer;
      if (trailer != null) {
        cleanBody = cleanBody.isEmpty ? trailer : '$cleanBody\n\n$trailer';
      }

      assistant = assistant.copyWith(
        body: cleanBody,
        citations: actionPass.toCitations(),
        streamingDone: true,
      );
      await repository.appendMessage(assistant);
      yield assistant;

      // Name the thread from its opening exchange — fire-and-forget so the
      // title write never delays the visible reply. Only on the first turn,
      // and only when a generator is wired (production); tests leave it null.
      // The attempt's future is parked on [debugAutoTitleSettled] so a test
      // can await its completion deterministically instead of sleeping a
      // guessed interval (and assert it was NOT attempted by checking the
      // field stayed null).
      if (isFirstTurn && titleGenerator != null) {
        final Future<void> attempt =
            _autoTitle(conversationId, userText, cleanBody);
        debugAutoTitleSettled = attempt;
        unawaited(attempt);
      }
    } catch (e, st) {
      // Never let a turn fail SILENTLY (alpha bug: "nothing happens after
      // I hit send"). Any exception after the user message — loadMessages,
      // a repo write, the action pass — becomes a visible, retryable error
      // bubble instead of an empty stream the screen swallows. The cause is
      // logged so the on-device failure can be diagnosed from a report.
      debugPrint('Chat sendMessage failed: $e\n$st');
      final Message errorMessage = assistant.copyWith(
        body: '$chatErrorMarkerPrefix $e]',
        citations: const <String>[],
        streamingDone: true,
      );
      try {
        await repository.appendMessage(errorMessage);
      } catch (_) {
        // Best-effort persist; the in-memory yield still surfaces it.
      }
      yield errorMessage;
    }
  }

  /// Best-effort: ask [titleGenerator] for a short name from the opening
  /// exchange and persist it as the thread's [Conversation.customTitle].
  /// Skips a thread the caregiver has already named (customTitle already
  /// set) so a rename is never clobbered. Never throws — a failed or empty
  /// title just leaves the derived succinct name in place.
  Future<void> _autoTitle(
    String conversationId,
    String userText,
    String assistantText,
  ) async {
    try {
      final Conversation? convo =
          await repository.getConversation(conversationId);
      if (convo == null || convo.customTitle) return;
      final String? raw = await titleGenerator!(<ChatTurn>[
        ChatTurn(role: MessageRole.user, content: userText),
        ChatTurn(role: MessageRole.assistant, content: assistantText),
      ]);
      final String? title = sanitizeChatTitle(raw);
      if (title == null) return;
      await repository.renameConversation(conversationId, title, custom: true);
    } catch (_) {
      // Auto-titling is a nicety, never a turn-failing path.
    }
  }

  /// Route one SPOKEN request from the hands-free center mic. Runs the
  /// transcript through the coach once in voice mode, then:
  ///   - reply carries an `[action:…]` tag → execute it and return a
  ///     [VoiceIntentAction] with the coach's short confirmation, so the UI
  ///     flashes an overlay and stays put — NO thread is created;
  ///   - otherwise it's a conversation → mint a thread, persist the spoken
  ///     turn + the reply, and return [VoiceIntentChat] so the UI opens it
  ///     with the answer already in place (no second model call).
  ///
  /// Never throws — a backend error degrades to opening a chat that carries
  /// the spoken turn + a visible, retryable error bubble.
  Future<VoiceIntentOutcome> routeVoiceIntent(String transcript) async {
    String systemPrompt = voiceIntentSystemPrompt;
    try {
      final String snapshot = await contextSnapshot();
      if (snapshot.trim().isNotEmpty) {
        systemPrompt = '$voiceIntentSystemPrompt\n\n$snapshot';
      }
    } catch (_) {
      systemPrompt = voiceIntentSystemPrompt;
    }

    final StringBuffer buffer = StringBuffer();
    try {
      await for (final ChatDelta delta in backend.streamReply(
        systemPrompt: systemPrompt,
        history: <ChatTurn>[
          ChatTurn(role: MessageRole.user, content: transcript),
        ],
      )) {
        switch (delta) {
          case ChatDeltaText(:final String text):
            buffer.write(text);
          case ChatDeltaError(:final String message):
            return _voiceToChat(transcript, '$chatErrorMarkerPrefix $message]');
        }
      }
    } catch (e, st) {
      debugPrint('Voice intent failed: $e\n$st');
      return _voiceToChat(transcript, '$chatErrorMarkerPrefix $e]');
    }

    final String rawBody = buffer.toString();
    // A crisis phrase in the SPOKEN message pins the trusted card too — route
    // to a chat (never a hands-free flash) so the resources card is visible.
    if (messageTriggersCrisis(transcript)) {
      return _voiceToChat(transcript, rawBody, crisis: true);
    }
    // Only treat it as an action when a RECOGNISED tag is present — the model
    // occasionally invents an unsupported name (e.g. `log_health_log` for the
    // real `add_health_log`), which would write nothing yet flash a false
    // "Done". An unknown/absent tag falls through to a chat so the caregiver
    // always sees a real response.
    final List<String> knownNames = _actionPattern
        .allMatches(rawBody)
        .map((RegExpMatch m) => m.group(1)!)
        .where(actions.containsKey)
        .toList(growable: false);
    // Every action that WRITES or CHANGES care data now confirms before it
    // applies (USER DECISION 2026-07): a med dosage, an appointment time, a
    // logged dose — none of it commits hands-free. Only pure navigation runs
    // instantly. So if the reply carries any mutating tag, open a chat whose
    // reply carries the pending confirm card(s); the caregiver taps once to
    // apply. A reply that carries ONLY instant (navigation) tags may still
    // complete hands-free.
    final bool hasMutating = knownNames.any(_isMutatingAction);
    if (knownNames.isNotEmpty && !hasMutating) {
      await _executeActions(rawBody, userText: transcript);
      final String confirmation = stripActionMarkers(rawBody);
      return VoiceIntentAction(
        summary: confirmation.isNotEmpty ? confirmation : 'Done.',
      );
    }
    return _voiceToChat(transcript, rawBody);
  }

  /// Persist a spoken turn + the coach's [rawBody] reply as a fresh thread
  /// and return its id, so the mic flow opens the chat with the answer
  /// already in place (no second model call). When [crisis] is true a trusted
  /// crisis-resources card is pinned above the reply (code-side, model-
  /// independent).
  Future<VoiceIntentOutcome> _voiceToChat(
      String transcript, String rawBody,
      {bool crisis = false}) async {
    final DateTime now = clock();
    final String conversationId = idFactory();
    await repository.createConversation(
      id: conversationId,
      title: _voiceThreadTitle(transcript),
      createdAt: now,
    );
    await repository.appendMessage(Message(
      id: idFactory(),
      conversationId: conversationId,
      role: MessageRole.user,
      body: transcript,
      citations: const <String>[],
      createdAt: now,
      streamingDone: true,
    ));
    if (crisis) {
      await repository.appendMessage(Message(
        id: idFactory(),
        conversationId: conversationId,
        role: MessageRole.assistant,
        body: '',
        citations: const <String>[crisisCardCitation],
        createdAt: now,
        streamingDone: true,
      ));
    }
    // A conversation reply rarely carries an action, but run any INSTANT
    // (navigation) one it does; every mutating tag surfaces here as a
    // pending confirm card in the thread rather than committing hands-free.
    final _ActionPass actionPass = await _executeActions(rawBody, userText: transcript);
    String body = stripActionMarkers(rawBody);
    final String? trailer = actionPass.failureTrailer;
    if (trailer != null) {
      body = body.isEmpty ? trailer : '$body\n\n$trailer';
    }
    await repository.appendMessage(Message(
      id: idFactory(),
      conversationId: conversationId,
      role: MessageRole.assistant,
      body: body,
      citations: actionPass.toCitations(),
      createdAt: now,
      streamingDone: true,
    ));
    return VoiceIntentChat(
      conversationId: conversationId,
      spokenReply: body,
    );
  }

  /// A short thread title from the spoken transcript (first ~40 chars).
  static String _voiceThreadTitle(String transcript) {
    final String t = transcript.trim();
    if (t.length <= 40) return t.isEmpty ? 'New chat' : t;
    return '${t.substring(0, 40).trimRight()}…';
  }

  /// Actions that REMOVE or CANCEL the caregiver's data — the sharpest
  /// subset of the mutating set. Kept named so the confirm-card copy can
  /// use removal-specific wording; gating no longer keys off this list
  /// alone (see [instantActionNames]).
  static const Set<String> destructiveActionNames = <String>{
    'delete_medication',
    'cancel_appointment',
    'delete_task',
  };

  /// The ONLY actions that run instantly from a model reply — pure
  /// navigation / read affordances that write nothing to the caregiver's
  /// care data. Everything else (add / update / log / complete / delete)
  /// WRITES or CHANGES data, so it is parked as a `pending_action:`
  /// citation and applied only after an explicit in-app confirm tap (USER
  /// DECISION 2026-07). In a caregiving app a silently changed med dosage
  /// or appointment time is a safety event — and a crafted name synced
  /// from a circle peer could otherwise smuggle such a tag into the prompt
  /// (indirect injection). Instant execution stays cheap and reversible:
  /// navigation only moves the caregiver around the app.
  static const Set<String> instantActionNames = <String>{
    'navigate',
  };

  /// True when [name] WRITES or CHANGES the caregiver's care data — i.e.
  /// any recognised action that isn't in [instantActionNames]. These gate
  /// behind the confirm card. Unknown names are treated as non-mutating
  /// here (they match no executor and are dropped downstream).
  bool _isMutatingAction(String name) =>
      actions.containsKey(name) && !instantActionNames.contains(name);

  /// Citation prefix marking a parsed-but-not-applied mutating action
  /// awaiting confirmation. The remainder of the citation is the raw
  /// `[action:…]` marker, re-parsed on confirm.
  static const String pendingActionCitationPrefix = 'pending_action:';

  /// Citation stamped on a TRUSTED, code-side crisis-resources card — a
  /// standalone assistant row (empty body) the chat surface renders as the
  /// 988 Lifeline card. Never emitted by the model; set only by the
  /// keyword watchdog in [sendMessage] / [routeVoiceIntent].
  static const String crisisCardCitation = 'crisis_resources';

  /// True when [message] is the trusted crisis card — an empty assistant
  /// row whose sole citation is [crisisCardCitation]. Excluded from the
  /// model's history (it's a UI pin, not a coach turn).
  static bool _isCrisisCardMessage(Message message) =>
      message.role == MessageRole.assistant &&
      message.body.isEmpty &&
      message.citations.length == 1 &&
      message.citations.first == crisisCardCitation;

  /// True when [citation] is the trusted crisis-card marker. The chat
  /// surface uses this to render the (non-LLM) resources card.
  static bool isCrisisCardCitation(String citation) =>
      citation == crisisCardCitation;

  /// True when [citation] is a pending-confirmation action chip.
  static bool isPendingActionCitation(String citation) =>
      citation.startsWith(pendingActionCitationPrefix);

  /// Human description of a pending action citation for the confirm card
  /// — one clear line showing exactly what will change ("Add the medication
  /// “Donepezil” (10 mg)?", "Change the dose of “Donepezil” to 5 mg?").
  /// Covers every mutating action the coach can propose, since ALL of them
  /// now confirm before applying (USER DECISION 2026-07). Falls back to a
  /// safe generic when the citation isn't a parseable pending action.
  static String? describePendingAction(String citation) {
    if (!isPendingActionCitation(citation)) return null;
    final String marker =
        citation.substring(pendingActionCitationPrefix.length);
    final RegExpMatch? m = _actionPattern.firstMatch(marker);
    if (m == null) return null;
    final Map<String, String> args = _parseActionArgs(m.group(2)!);
    String? arg(String key) {
      final String v = (args[key] ?? '').trim();
      return v.isEmpty ? null : v;
    }

    switch (m.group(1)) {
      case 'add_medication':
        final String? name = arg('name');
        final String? dosage = arg('dosage');
        if (name == null) return 'Add this medication to the list?';
        return dosage == null
            ? 'Add the medication “$name” to the list?'
            : 'Add the medication “$name” ($dosage)?';
      case 'update_medication':
        final String? name = arg('name');
        final String label =
            name == null ? 'this medication' : '“$name”';
        final String? dosage = arg('dosage');
        final String? newName = arg('new_name');
        if (dosage != null) return 'Change the dose of $label to $dosage?';
        if (newName != null) return 'Rename $label to “$newName”?';
        return 'Update $label?';
      case 'delete_medication':
        final String? name = arg('name');
        return name == null
            ? 'Remove this medication from the list?'
            : 'Remove the medication “$name” from the list?';
      case 'add_appointment':
        final String? provider = arg('provider_name');
        final String? when = arg('starts_at');
        final String who =
            provider == null ? 'this appointment' : 'the appointment with $provider';
        return when == null ? 'Schedule $who?' : 'Schedule $who for $when?';
      case 'update_appointment':
        final String? provider = arg('provider_name');
        final String who = provider == null
            ? 'this appointment'
            : 'the appointment with $provider';
        final String? when = arg('starts_at');
        return when == null ? 'Update $who?' : 'Move $who to $when?';
      case 'cancel_appointment':
        final String? provider = arg('provider_name');
        return provider == null
            ? 'Cancel this appointment?'
            : 'Cancel the appointment with $provider?';
      case 'add_task':
        final String? title = arg('title');
        return title == null
            ? 'Add this task for the care team?'
            : 'Add the task “$title” for the care team?';
      case 'complete_task':
        final String? title = arg('title');
        return title == null
            ? 'Mark this task done?'
            : 'Mark the task “$title” done?';
      case 'delete_task':
        final String? title = arg('title');
        return title == null
            ? 'Delete this task?'
            : 'Delete the task “$title”?';
      case 'add_routine':
        final String? name = arg('name') ?? arg('title');
        final String? time = arg('time');
        if (name == null) return 'Add this routine to the schedule?';
        return time == null
            ? 'Add the routine “$name”?'
            : 'Add the routine “$name” at $time?';
      case 'add_health_log':
        final String? value = arg('value') ?? arg('note');
        return value == null
            ? 'Add this to the health log?'
            : 'Add to the health log: “$value”?';
      case 'log_dose':
        final String? name = arg('name');
        final String outcome = arg('outcome') ?? 'taken';
        return name == null
            ? 'Record this dose?'
            : 'Record “$name” as $outcome?';
      case 'log_journal':
        final String? situation = arg('situation');
        return situation == null
            ? 'Save this journal entry?'
            : 'Save a journal entry: “$situation”?';
    }
    return null;
  }

  /// Run every recognised `[action:…]` marker the assistant emitted in
  /// [body] against the wired executors. Unrecognised actions are
  /// silently dropped (the marker still gets stripped from the
  /// displayed body via [stripActionMarkers]) — better to lose a tool
  /// call than to fail the whole turn. MUTATING actions (anything that
  /// writes/changes care data — everything but [instantActionNames]) are
  /// NOT run here: they come back in [_ActionPass.pendingMarkers] for the
  /// confirm-card flow. Only instant (navigation) actions execute. Identical
  /// repeated tags are deduplicated (a model that stutters the same tag
  /// twice must not double-write). A throwing instant executor no longer
  /// vanishes silently — it flips [_ActionPass.hadFailure] so the caller can
  /// tell the caregiver the save failed instead of letting the prose lie.
  /// Repair a mangled `starts_at` on an appointment marker before it is parked.
  ///
  /// The 70b model reliably identifies WHEN a caregiver wants a visit but botches
  /// the date string it writes ("2026-0712:00", day dropped). The caregiver's own
  /// words carry the real intent, so: if the marker's date won't resolve but their
  /// message does ("tomorrow at noon"), rewrite starts_at to the resolved absolute
  /// date. Only touches appointment markers; leaves a good date alone.
  String _repairAppointmentDate(String name, String raw, String? userText) {
    if (name != 'add_appointment' && name != 'update_appointment') return raw;
    final Map<String, String> args =
        _parseActionArgs(_actionPattern.firstMatch(raw)!.group(2)!);
    // Already resolvable? Leave it.
    if (resolveDateTimeIso(args['starts_at'], clock) != null) return raw;
    // Fall back to the caregiver's message.
    final String? fixed = resolveDateTimeIso(userText, clock);
    if (fixed == null) return raw; // nothing better to offer
    final String current = args['starts_at'] ?? '';
    if (current.isEmpty) {
      // Insert a starts_at right after the action name.
      return raw.replaceFirst(
          RegExp(r'\[action:(add|update)_appointment'),
          '[action:$name starts_at="$fixed"');
    }
    // Replace the existing (bad) value.
    return raw.replaceFirst(
        RegExp('starts_at\\s*=\\s*"?${RegExp.escape(current)}"?'),
        'starts_at="$fixed"');
  }

  Future<_ActionPass> _executeActions(String body, {String? userText}) async {
    final List<_ActionResult> results = <_ActionResult>[];
    final List<String> pendingMarkers = <String>[];
    final Set<String> seenMarkers = <String>{};
    final List<String> failureNotices = <String>[];
    final List<String> noticeLines = <String>[];
    bool hadFailure = false;
    for (final RegExpMatch m in _actionPattern.allMatches(body)) {
      final String raw = m.group(0)!;
      if (!seenMarkers.add(raw)) continue; // duplicate tag — run once
      final String name = m.group(1)!;
      final ChatActionExecutor? executor = actions[name];
      if (executor == null) continue; // unknown / unwired tool — skip
      if (_isMutatingAction(name)) {
        // The model mangles appointment dates it has to compute ("2026-0712:00").
        // A mutating action PARKS as a citation and runs on confirm, where the
        // caregiver's message is long gone — so repair the date NOW, from their
        // own words ("tomorrow at noon"), before the marker is stored.
        pendingMarkers.add(_repairAppointmentDate(name, raw, userText));
        continue;
      }
      final Map<String, String> args = _parseActionArgs(m.group(2)!);
      try {
        final ChatActionOutcome? outcome = await executor(args);
        // An executor that DIDN'T perform its write must not pass as success.
        // A null outcome counts as "did nothing" — the safe reading, since the
        // prose has already told the caregiver it happened. (2026-07-13: an
        // `add_medication` with no dose returned null, wrote nothing, and the
        // coach still said it was added.)
        if (outcome == null || !outcome.performed) {
          hadFailure = true;
          final String? why = outcome?.failure;
          if (why != null) failureNotices.add(why);
          continue;
        }
        // The action DID happen — but maybe not exactly as asked (a dose window
        // we had to invent, a name that matched nothing). "Mostly did it" must
        // not read as "did it", so the disclosure rides along with the reply.
        final String? notice = outcome.notice;
        if (notice != null) noticeLines.add(notice);
        final String? citation = outcome.citation;
        if (citation != null) {
          results.add(_ActionResult(citation: citation));
        }
      } catch (e, st) {
        // The prose already lives in the bubble and may claim success, so a
        // silent swallow would leave the caregiver believing something saved
        // that didn't. Flag it; the caller appends an honest failure line.
        debugPrint('Chat action "$name" failed: $e\n$st');
        hadFailure = true;
      }
    }
    return _ActionPass(
      results: results,
      pendingMarkers: pendingMarkers,
      hadFailure: hadFailure,
      failureNotices: failureNotices,
      notices: noticeLines,
    );
  }

  /// Apply a mutating action the caregiver just CONFIRMED via its in-thread
  /// card (any write/change — add, update, log, complete, or a removal).
  /// Re-parses the marker stored in [citation], runs the executor, and
  /// rewrites the message's citations — the pending chip is removed either
  /// way (one decision per card), and a successful execution contributes the
  /// executor's own citation when it has one. Returns true when the action
  /// actually ran.
  Future<bool> confirmPendingAction({
    required String conversationId,
    required String messageId,
    required String citation,
  }) async {
    final String marker = isPendingActionCitation(citation)
        ? citation.substring(pendingActionCitationPrefix.length)
        : citation;
    final RegExpMatch? m = _actionPattern.firstMatch(marker);
    bool ran = false;
    String? executedCitation;
    if (m != null) {
      final ChatActionExecutor? executor = actions[m.group(1)!];
      if (executor != null) {
        try {
          final ChatActionOutcome? outcome =
              await executor(_parseActionArgs(m.group(2)!));
          // `ran` must mean the write LANDED — not merely "the executor didn't
          // throw". It used to mean the latter, so a confirm card reported
          // success for an executor that quietly did nothing: the tester
          // confirmed "add ibuprofen", the card said done, and no medication
          // was ever created (2026-07-13).
          ran = outcome != null && outcome.performed;
          executedCitation = ran ? outcome.citation : null;
        } catch (e, st) {
          // The confirm card reports ran=false to the UI (which shows an
          // honest "couldn't make that change" line); log the cause so the
          // on-device failure is diagnosable from a report.
          debugPrint('Confirmed chat action failed: $e\n$st');
          ran = false;
        }
      }
    }
    await _replaceCitation(
      conversationId: conversationId,
      messageId: messageId,
      citation: citation,
      replacement: executedCitation,
    );
    return ran;
  }

  /// The caregiver declined the confirm card — drop the pending citation
  /// without executing anything. Idempotent.
  Future<void> declinePendingAction({
    required String conversationId,
    required String messageId,
    required String citation,
  }) =>
      _replaceCitation(
        conversationId: conversationId,
        messageId: messageId,
        citation: citation,
        replacement: null,
      );

  /// Rewrite one message's citations: remove [citation], append
  /// [replacement] when non-null. No-op when the message or citation is
  /// already gone (double-tap, stale UI).
  Future<void> _replaceCitation({
    required String conversationId,
    required String messageId,
    required String citation,
    required String? replacement,
  }) async {
    final List<Message> messages =
        await repository.loadMessages(conversationId);
    for (final Message message in messages) {
      if (message.id != messageId) continue;
      if (!message.citations.contains(citation)) return;
      final List<String> updated = <String>[
        for (final String c in message.citations)
          if (c != citation) c,
        if (replacement != null) replacement,
      ];
      await repository.appendMessage(message.copyWith(citations: updated));
      return;
    }
  }

  /// Strip every recognised `[action:…]` marker from [body] so the
  /// rendered bubble doesn't show the raw tool tag. Idempotent and
  /// safe to call on bodies with zero markers — used by the chat
  /// surface tests to assert clean rendering without standing up an
  /// executor.
  static String stripActionMarkers(String body) {
    final String stripped = body.replaceAll(_actionPattern, '');
    // Collapse the trailing whitespace + double-newlines the model
    // sometimes leaves when the action is on its own line at the end.
    return stripped.trimRight();
  }

  /// Render [body] as the caregiver should SEE it — the single chokepoint
  /// every display surface (conversation-list preview, the chat bubble
  /// while streaming, the finalised bubble) funnels through so no internal
  /// marker leaks to the UI:
  ///
  ///   - `[action:…]` tool tags are stripped (the action still ran; only
  ///     the tag is hidden), via [stripActionMarkers].
  ///   - A `[chat error: <raw transport detail>]` trailer is replaced
  ///     wholesale by [chatFriendlyErrorMessage]. The raw detail can carry
  ///     a `]` of its own (e.g. `DioException [connection error]: …`), so
  ///     we cut from the sentinel to the END of the body rather than to the
  ///     first bracket — the service always appends this trailer last, so
  ///     everything from it on is the error payload.
  ///
  /// The stored body is untouched: [chatBodyHasError] still matches the raw
  /// sentinel to drive the inline retry; this transform is render-only.
  static String displayBody(String body) {
    final int errIdx = body.indexOf(chatErrorMarkerPrefix);
    if (errIdx == -1) {
      return stripActionMarkers(body);
    }
    final String prose = stripActionMarkers(body.substring(0, errIdx));
    String friendly = chatFriendlyErrorMessage;
    // Alpha builds append the raw cause so a tester can screenshot the exact
    // failure (production hides it behind the friendly line). Render-only.
    if (feedbackUiEnabled) {
      String raw = body.substring(errIdx + chatErrorMarkerPrefix.length).trim();
      if (raw.endsWith(']')) raw = raw.substring(0, raw.length - 1).trim();
      if (raw.isNotEmpty) {
        friendly = '$chatFriendlyErrorMessage\n\n(alpha detail: $raw)';
      }
    }
    if (prose.isEmpty) return friendly;
    // Keep any partial reply that streamed before the failure, then the
    // friendly line on its own paragraph.
    return '$prose\n\n$friendly';
  }

  /// Parse `key="value" key2="value with \" escape"` into a map. Bare
  /// (unquoted) values are tolerated too — the prompt asks for quotes
  /// but a stray model output shouldn't drop the action.
  static Map<String, String> _parseActionArgs(String raw) {
    final Map<String, String> out = <String, String>{};
    final RegExp pair = RegExp(
      r'([a-z_]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|(\S+))',
    );
    for (final RegExpMatch m in pair.allMatches(raw)) {
      final String key = m.group(1)!;
      final String value = m.group(2) ?? m.group(3) ?? '';
      final String unescaped = value
          .replaceAll(r'\"', '"')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\\', r'\');
      _hoistRunTogetherArgs(key, unescaped, out);
    }
    return out;
  }

  /// Repair the model's most common marker mistake: stuffing a SECOND field
  /// inside the first one's quotes.
  ///
  /// Seen on a real device (2026-07-13), from the deployed 70b model:
  ///
  ///   [action:add_medication name="Ibuprofen dosage=400 mg" route="oral" …]
  ///
  /// The parser then read name = `Ibuprofen dosage=400 mg` and NO dosage — so
  /// the medication could not be added, the confirm card failed, and the
  /// caregiver was told it hadn't worked with no idea why. Scripted-marker unit
  /// tests can never catch this; only the live model produces it.
  ///
  /// So when a value contains an embedded `key=…` for a key we recognise, split
  /// it back out: `Ibuprofen dosage=400 mg` → name=`Ibuprofen`, dosage=`400 mg`.
  /// An explicit later pair always wins over a hoisted one, so a well-formed
  /// marker is untouched.
  static void _hoistRunTogetherArgs(
    String key,
    String value,
    Map<String, String> out,
  ) {
    final RegExp embedded = RegExp(r'\s+([a-z_]+)\s*=\s*(.+)$');
    final RegExpMatch? m = embedded.firstMatch(value);
    if (m == null || !_knownActionArgKeys.contains(m.group(1))) {
      // No embedded field (or a word that merely looks like one) — take it as
      // written. An explicit pair parsed later overwrites any hoisted value.
      out[key] = out.containsKey(key) && value.isEmpty ? out[key]! : value;
      return;
    }
    out[key] = value.substring(0, m.start).trim();
    // The tail may itself carry more run-together fields.
    _hoistRunTogetherArgs(m.group(1)!, m.group(2)!.trim(), out);
  }

  /// Argument names any action may carry. Used ONLY to decide whether an
  /// embedded `word=…` inside a quoted value is a mangled field or just prose
  /// (so "notes=take with food" hoists, but a note that happens to read
  /// "ratio=2:1" does not invent an arg).
  static const Set<String> _knownActionArgKeys = <String>{
    'name', 'new_name', 'dosage', 'route', 'prescriber', 'notes', 'windows',
    'title', 'body', 'due_at', 'provider_name', 'starts_at',
    'duration_minutes', 'location', 'agenda', 'situation', 'attempts',
    'occurred_at', 'time', 'frequency', 'days', 'kind', 'weight_lbs',
    'recorded_at', 'outcome', 'target', 'date',
  };

}

/// Deterministic, offline [ChatLLMBackend] for demo + test builds —
/// the chat counterpart of [FakeLLMProvider]. Streams a short, canned,
/// coaching-voice reply in word chunks (so the streaming UI animates
/// exactly as live) chosen by simple keyword so the pitch demo feels
/// responsive without a network, a shim, or nondeterminism. Never emits
/// an `[action:…]` tag — demo chat reads, it doesn't write.
class DemoChatBackend implements ChatLLMBackend {
  const DemoChatBackend({this.chunkDelay = const Duration(milliseconds: 40)});

  final Duration chunkDelay;

  static const String _sleepReply =
      'Nights are the hardest shift of all — you are not doing this '
      'wrong. Try a low light and a calm line: "You\'re safe. I\'m '
      'right here with you." Keep the room boring on purpose; '
      'stimulation reads as morning. If tonight stays rough, rest when '
      'she rests tomorrow — the chores can wait.';

  static const String _eatingReply =
      'Appetite fades before hunger does — this is the disease, not '
      'your cooking. Offer one food at a time on a plain plate, and '
      'sit and eat WITH her: "I made us a little something." Finger '
      'foods beat cutlery on hard days. Note what she does eat and '
      'bring the list to her doctor.';

  static const String _defaultReply =
      'That sounds like a heavy moment, and you handled it by being '
      'there — that counts. Step into her reality rather than '
      'correcting it: "You\'re safe. I\'ve got it handled." Then '
      'redirect to something familiar — a photo, a song, folding warm '
      'towels. You are doing better than you think.';

  static String replyFor(String latestUserText) {
    final String t = latestUserText.toLowerCase();
    if (t.contains('sleep') || t.contains('night') || t.contains('awake')) {
      return _sleepReply;
    }
    if (t.contains('eat') || t.contains('food') || t.contains('meal')) {
      return _eatingReply;
    }
    return _defaultReply;
  }

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    final String latest = history.isEmpty ? '' : history.last.content;
    final String reply = replyFor(latest);
    final List<String> words = reply.split(' ');
    final StringBuffer chunk = StringBuffer();
    for (int i = 0; i < words.length; i++) {
      chunk.write(words[i]);
      if (i < words.length - 1) chunk.write(' ');
      if ((i + 1) % 4 == 0 || i == words.length - 1) {
        yield ChatDeltaText(chunk.toString());
        chunk.clear();
        if (i < words.length - 1) {
          await Future<void>.delayed(chunkDelay);
        }
      }
    }
  }
}

/// Riverpod-wired chat backend (TASKS.md Phase 11.3). Real shim-backed
/// impl by default; the deterministic [DemoChatBackend] under the same
/// fake-engine rule the recap uses (`flutter test`, or an explicit
/// `--dart-define=USE_FAKE_LLM=true` — the DEMO_MODE pitch build sets
/// it), so a demo run's chat never depends on the network. Test
/// harnesses still override this provider with their own scripted
/// backends.
@Riverpod(keepAlive: true)
ChatLLMBackend chatLLMBackend(Ref ref) {
  // Deterministic fake first (every `flutter test`, and the DEMO_MODE
  // pitch build via --dart-define=USE_FAKE_LLM=true) — never touches the
  // network.
  if (useFakeLLMEngine) return const DemoChatBackend();
  // Shipped/alpha build with a real Worker baked in
  // (--dart-define=FORUM_API_URL=...) → route the coach THROUGH the Worker
  // so per-user quotas + the global daily spend cap are enforced and the
  // inference key never lives on-device. The session JWT (with refresh) is
  // supplied by ForumSessionManager.
  if (forumBackendConfigured) {
    return ApiChatBackend(
      baseUrl: forumApiBaseUrl,
      tokenLoader: ref.watch(forumSessionManagerProvider).currentToken,
    );
  }
  // No backend configured → the local dev shim (localhost:8765 / SHIM_URL).
  return const ClaudeShimChatBackend();
}

/// Riverpod-wired singleton (TASKS.md Phase 11.3). Screens and tests
/// that want the chat orchestrator read `ref.watch(chatServiceProvider)`
/// and get one instance shared across the app — the backend and
/// repository are themselves singletons, so the wrapper is cheap to
/// keep alive.
///
/// The action registry comes from [buildChatActions], which holds [ref]
/// so each tool reaches its repository through the same provider graph the
/// screens use — a Settings override of any backend flows through without
/// rebuilding the chat service.
@Riverpod(keepAlive: true)
ChatService chatService(Ref ref) => ChatService(
      repository: ref.watch(chatRepositoryProvider),
      backend: ref.watch(chatLLMBackendProvider),
      actions: buildChatActions(ref, clock: DateTime.now),
      // Read the caregiver's current data fresh each turn through the same
      // provider graph the screens use, then render it to the compact
      // CURRENT DATA block the coach reads.
      contextSnapshot: () async =>
          formatChatContext(await gatherChatContext(ref)),
      titleGenerator: ref.watch(chatTitleGeneratorProvider),
    );

/// The auto-title generator wired into [chatService] (fb_1781115614890041).
/// A separate, overridable seam so a fresh thread is named from its opening
/// exchange in production WITHOUT the title's extra backend round-trip
/// polluting tests that count reply calls — flow/integration tests override
/// this with a no-op (or null) to keep `backend.callCount` equal to the
/// number of reply round-trips. Reuses the same chat backend the replies
/// stream through, so a Settings backend override flows through here too.
@Riverpod(keepAlive: true)
ChatTitleGenerator chatTitleGenerator(Ref ref) =>
    (List<ChatTurn> turns) =>
        generateChatTitle(ref.read(chatLLMBackendProvider), turns);

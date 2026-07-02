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
          // once when it's finished (the decoder/recap leave this off).
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
    // into a replacement char — Dr. Natali's voice includes em-dashes
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
/// executed actions plus the RAW markers of destructive actions that
/// were parsed but deliberately NOT executed (they await the
/// caregiver's explicit in-app confirmation).
class _ActionPass {
  const _ActionPass({
    this.results = const <_ActionResult>[],
    this.pendingMarkers = const <String>[],
  });

  final List<_ActionResult> results;
  final List<String> pendingMarkers;

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
  const VoiceIntentChat({required this.conversationId});
  final String conversationId;
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
///   4. On stream-close, parse `[card:<id>]` markers in the final body
///      into the [Message.citations] list (deduplicated, first-seen
///      order) and flip `streamingDone: true`.
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
      // the latest entry is the one to reply to.
      final List<Message> history =
          await repository.loadMessages(conversationId);
      final List<ChatTurn> turns = history
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
      final _ActionPass actionPass = await _executeActions(rawBody);
      final String cleanBody = stripActionMarkers(rawBody);

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
    // Destructive intents NEVER complete hands-free: the turn opens as a
    // chat whose reply carries the pending confirm card, so removing a
    // medication / cancelling a visit always takes a deliberate tap.
    final bool hasDestructive = knownNames.any(destructiveActionNames.contains);
    if (knownNames.isNotEmpty && !hasDestructive) {
      await _executeActions(rawBody);
      final String confirmation = stripActionMarkers(rawBody);
      return VoiceIntentAction(
        summary: confirmation.isNotEmpty ? confirmation : 'Done.',
      );
    }
    return _voiceToChat(transcript, rawBody);
  }

  /// Persist a spoken turn + the coach's [rawBody] reply as a fresh thread
  /// and return its id, so the mic flow opens the chat with the answer
  /// already in place (no second model call).
  Future<VoiceIntentOutcome> _voiceToChat(
      String transcript, String rawBody) async {
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
    // A conversation reply rarely carries an action, but run any it does so
    // a mixed reply still writes; the bubble shows the clean prose.
    // Destructive tags surface here as pending confirm cards in the thread.
    final _ActionPass actionPass = await _executeActions(rawBody);
    await repository.appendMessage(Message(
      id: idFactory(),
      conversationId: conversationId,
      role: MessageRole.assistant,
      body: stripActionMarkers(rawBody),
      citations: actionPass.toCitations(),
      createdAt: now,
      streamingDone: true,
    ));
    return VoiceIntentChat(conversationId: conversationId);
  }

  /// A short thread title from the spoken transcript (first ~40 chars).
  static String _voiceThreadTitle(String transcript) {
    final String t = transcript.trim();
    if (t.length <= 40) return t.isEmpty ? 'New chat' : t;
    return '${t.substring(0, 40).trimRight()}…';
  }

  /// Actions that REMOVE or CANCEL the caregiver's data. These are never
  /// auto-executed from a model reply — in a caregiving app a silently
  /// deleted medication or cancelled appointment is a safety event, and
  /// a crafted journal/med name synced from a circle peer could otherwise
  /// smuggle such a tag into the prompt (indirect injection). They are
  /// parked as `pending_action:` citations and run only through
  /// [confirmPendingAction] after an explicit in-app tap.
  static const Set<String> destructiveActionNames = <String>{
    'delete_medication',
    'cancel_appointment',
    'delete_task',
  };

  /// Citation prefix marking a parsed-but-not-executed destructive action
  /// awaiting confirmation. The remainder of the citation is the raw
  /// `[action:…]` marker, re-parsed on confirm.
  static const String pendingActionCitationPrefix = 'pending_action:';

  /// True when [citation] is a pending-confirmation action chip.
  static bool isPendingActionCitation(String citation) =>
      citation.startsWith(pendingActionCitationPrefix);

  /// Human description of a pending action citation for the confirm card
  /// ("Remove the medication “Ibuprofen”?"). Null when the citation isn't
  /// a parseable pending action (the card then renders a generic label).
  static String? describePendingAction(String citation) {
    if (!isPendingActionCitation(citation)) return null;
    final String marker =
        citation.substring(pendingActionCitationPrefix.length);
    final RegExpMatch? m = _actionPattern.firstMatch(marker);
    if (m == null) return null;
    final Map<String, String> args = _parseActionArgs(m.group(2)!);
    switch (m.group(1)) {
      case 'delete_medication':
        final String? name = args['name'];
        return name == null || name.trim().isEmpty
            ? 'Remove this medication from the list?'
            : 'Remove the medication “${name.trim()}” from the list?';
      case 'cancel_appointment':
        final String? provider = args['provider_name'];
        return provider == null || provider.trim().isEmpty
            ? 'Cancel this appointment?'
            : 'Cancel the appointment with ${provider.trim()}?';
      case 'delete_task':
        final String? title = args['title'];
        return title == null || title.trim().isEmpty
            ? 'Delete this task?'
            : 'Delete the task “${title.trim()}”?';
    }
    return null;
  }

  /// Run every recognised `[action:…]` marker the assistant emitted in
  /// [body] against the wired executors. Unrecognised actions are
  /// silently dropped (the marker still gets stripped from the
  /// displayed body via [stripActionMarkers]) — better to lose a tool
  /// call than to fail the whole turn. Destructive actions are NOT run:
  /// they come back in [_ActionPass.pendingMarkers] for the confirm-card
  /// flow. Identical repeated tags are deduplicated (a model that
  /// stutters the same tag twice must not double-write).
  Future<_ActionPass> _executeActions(String body) async {
    final List<_ActionResult> results = <_ActionResult>[];
    final List<String> pendingMarkers = <String>[];
    final Set<String> seenMarkers = <String>{};
    for (final RegExpMatch m in _actionPattern.allMatches(body)) {
      final String raw = m.group(0)!;
      if (!seenMarkers.add(raw)) continue; // duplicate tag — run once
      final String name = m.group(1)!;
      final ChatActionExecutor? executor = actions[name];
      if (executor == null) continue; // unknown / unwired tool — skip
      if (destructiveActionNames.contains(name)) {
        pendingMarkers.add(raw);
        continue;
      }
      final Map<String, String> args = _parseActionArgs(m.group(2)!);
      try {
        final ChatActionOutcome? outcome = await executor(args);
        final String? citation = outcome?.citation;
        if (citation != null) {
          results.add(_ActionResult(citation: citation));
        }
      } catch (_) {
        // Executor failure swallowed deliberately: the assistant's prose
        // already lives in the bubble; surfacing a "tool failed" footer
        // would derail the conversation. The marker is still stripped.
      }
    }
    return _ActionPass(results: results, pendingMarkers: pendingMarkers);
  }

  /// Execute a destructive action the caregiver just CONFIRMED via its
  /// in-thread card. Re-parses the marker stored in [citation], runs the
  /// executor, and rewrites the message's citations — the pending chip is
  /// removed either way (one decision per card), and a successful
  /// execution contributes the executor's own citation when it has one.
  /// Returns true when the action actually ran.
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
          executedCitation = outcome?.citation;
          ran = true;
        } catch (_) {
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
      out[key] = value
          .replaceAll(r'\"', '"')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\\', r'\');
    }
    return out;
  }

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
/// fake-engine rule the decoder uses (`flutter test`, or an explicit
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

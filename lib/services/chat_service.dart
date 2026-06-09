import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/chat.dart';
import '../providers/llm_provider.dart'
    show claudeShimEndpoint, shimAuthHeaders;
import '../seed/chat_system_prompt.dart';
import 'chat_actions.dart';
import 'chat_context_builder.dart';
import 'chat_repository.dart';
import 'feedback_service.dart' show alphaFeedbackEnabled;

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
            ? 'Careblazer'
            : 'Coach';
        sb.writeln('$label: ${turn.content}');
      }
      sb.writeln();
    }
    sb.writeln('[Latest Careblazer message]');
    sb.write(history.last.content);
    return sb.toString();
  }

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    final Dio dio = _injectedDio ?? Dio();
    final String userMessage = formatHistory(history);

    Response<ResponseBody> response;
    try {
      response = await dio.post<ResponseBody>(
        endpoint,
        data: <String, String>{
          'system': systemPrompt,
          'user': userMessage,
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
    try {
      await for (final Uint8List bytes in body.stream) {
        rawBuffer.addAll(bytes);
        while (true) {
          final int sep = _indexOfDoubleNewline(rawBuffer);
          if (sep == -1) break;
          final List<int> eventBytes = rawBuffer.sublist(0, sep);
          rawBuffer.removeRange(0, sep + 2);
          final String event = utf8.decode(eventBytes);
          for (final ChatDelta? d in _eventsFromBlock(event)) {
            if (d == null) continue;
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
        for (final ChatDelta? d in _eventsFromBlock(trailing)) {
          if (d == null) continue;
          yield d;
          if (d is ChatDeltaError) return;
        }
      }
    } catch (e) {
      yield ChatDeltaError('stream read failed: $e');
    }
  }

  /// Parse one `\n\n`-delimited block of `data:` lines into zero or
  /// more deltas. A `null` slot represents a no-op event (init line,
  /// `[DONE]` terminator, untyped payload) that the caller should skip.
  static Iterable<ChatDelta?> _eventsFromBlock(String block) sync* {
    for (final String line in block.split('\n')) {
      if (!line.startsWith('data:')) continue;
      final String payload = line.substring(5).startsWith(' ')
          ? line.substring(6)
          : line.substring(5);
      if (payload == '[DONE]') {
        yield null;
        continue;
      }
      final _ChatEventPayload parsed = _parseEvent(payload);
      if (parsed.error != null) {
        yield ChatDeltaError(parsed.error!);
        continue;
      }
      if (parsed.text == null || parsed.text!.isEmpty) {
        yield null;
        continue;
      }
      yield ChatDeltaText(parsed.text!);
    }
  }

  static int _indexOfDoubleNewline(List<int> bytes) {
    for (int i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0x0A && bytes[i + 1] == 0x0A) return i;
    }
    return -1;
  }

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
  const _ChatEventPayload({this.text, this.error});
  final String? text;
  final String? error;
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

/// Default [ChatService.contextSnapshot] — no data injected. Keeps the
/// service unit-testable (the prompt equals [chatSystemPrompt] unchanged)
/// and chat-only surfaces wiring-free.
Future<String> _emptyContextSnapshot() async => '';

/// Pattern for `[action:<name> key="value" …]` tool-call markers in a
/// finished assistant reply. v1 surfaces a single action — `log_journal`
/// — but the parser is generic so a second action only needs an
/// executor wired in [ChatService].
///
/// `body` group: the action name (e.g. `log_journal`).
/// `args` group: the raw "key=value …" tail to feed [_parseActionArgs].
final RegExp _actionPattern = RegExp(
  r'\[action:([a-z_]+)\s+([^\]]+)\]',
);

/// Action-execution result the orchestrator stamps into the assistant
/// message's [Message.citations] list. Carries the citation a chip
/// renderer can deep-link from.
class _ActionResult {
  const _ActionResult({required this.citation});
  final String citation;
}

/// Multi-turn dementia-care chat orchestrator (TASKS.md Phase 11.3).
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
      final List<_ActionResult> actionResults = await _executeActions(rawBody);
      final String cleanBody = stripActionMarkers(rawBody);

      assistant = assistant.copyWith(
        body: cleanBody,
        citations: actionResults
            .map((_ActionResult r) => r.citation)
            .toList(growable: false),
        streamingDone: true,
      );
      await repository.appendMessage(assistant);
      yield assistant;
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

  /// Run every recognised `[action:…]` marker the assistant emitted in
  /// [body] against the wired executors. Unrecognised actions are
  /// silently dropped (the marker still gets stripped from the
  /// displayed body via [stripActionMarkers]) — better to lose a tool
  /// call than to fail the whole turn.
  Future<List<_ActionResult>> _executeActions(String body) async {
    final List<_ActionResult> results = <_ActionResult>[];
    for (final RegExpMatch m in _actionPattern.allMatches(body)) {
      final String name = m.group(1)!;
      final ChatActionExecutor? executor = actions[name];
      if (executor == null) continue; // unknown / unwired tool — skip
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
    return results;
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
    if (alphaFeedbackEnabled) {
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

/// Riverpod-wired chat backend (TASKS.md Phase 11.3). Defaults to the
/// real [ClaudeShimChatBackend] so `flutter run` with the local shim
/// up streams real replies; test harnesses override this provider
/// with their own scripted backend.
@Riverpod(keepAlive: true)
ChatLLMBackend chatLLMBackend(Ref ref) => const ClaudeShimChatBackend();

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
    );

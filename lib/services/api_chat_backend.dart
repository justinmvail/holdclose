import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../providers/llm_provider.dart' show buildShimDio;
import 'chat_service.dart';
import 'forum_api_client.dart' show forumApiVersionPrefix;

/// Async producer of the server-minted forum session JWT for the
/// `Authorization` header. Production wires this to
/// `ForumSessionManager.currentToken` (handles refresh); tests inject a
/// constant closure.
typedef ChatTokenLoader = Future<String> Function();

/// Production [ChatLLMBackend] for shipped builds: streams the coach reply
/// through the **Cloudflare Worker** (`POST /api/v1/chat`) instead of
/// hitting an LLM host directly. This is the prod counterpart to
/// [ClaudeShimChatBackend] (dev shim) and [DemoChatBackend] (fake).
///
/// Why the indirection: the Worker is the gatekeeping chokepoint — it
/// holds the inference-host API key (never on-device), enforces per-user
/// daily token quotas + a global daily spend cap, and logs token usage.
/// The app just sends `{system, user}` with its JWT and consumes a
/// vendor-neutral SSE stream (`data: {"text":"…"}` per fragment, then
/// `data: [DONE]`; `data: {"error":"…"}` on failure). The model/vendor
/// never appears on the wire, so no UI string can leak it.
///
/// History is collapsed into the single `user` payload via
/// [ClaudeShimChatBackend.formatHistory] — the exact shape the shim path
/// already uses, so the Worker, shim, and fake all speak one contract.
class ApiChatBackend implements ChatLLMBackend {
  ApiChatBackend({
    required this.baseUrl,
    required this.tokenLoader,
    Dio? dio,
  }) : _injectedDio = dio;

  /// The Worker origin (`FORUM_API_URL`); the route prefix is appended.
  final String baseUrl;

  /// Supplies a fresh session JWT per request (refresh handled upstream).
  final ChatTokenLoader tokenLoader;

  /// Injected for tests — production builds a fresh bounded [Dio] per
  /// request (shared timeout policy with the shim backend).
  final Dio? _injectedDio;

  String get _endpoint {
    final String trimmed =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$trimmed$forumApiVersionPrefix/chat';
  }

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    final Dio dio = _injectedDio ?? buildShimDio();
    final String userMessage = ClaudeShimChatBackend.formatHistory(history);

    String token;
    try {
      token = await tokenLoader();
    } catch (e) {
      // No usable session — surface as a chat error (ChatService folds it
      // into the friendly "couldn't reach the coach" trailer).
      yield ChatDeltaError('chat auth failed: $e');
      return;
    }

    Response<ResponseBody> response;
    try {
      response = await dio.post<ResponseBody>(
        _endpoint,
        data: <String, dynamic>{
          'system': systemPrompt,
          'user': userMessage,
          // Per-surface accounting tag (logged to llm_usage.feature).
          'feature': 'chat',
        },
        options: Options(
          responseType: ResponseType.stream,
          contentType: Headers.jsonContentType,
          headers: <String, Object>{'Authorization': 'Bearer $token'},
          // Read the status ourselves so a 429/503/413 becomes a clean
          // ChatDeltaError instead of a thrown DioException.
          validateStatus: (_) => true,
        ),
      );
    } catch (e) {
      yield ChatDeltaError('chat request failed: $e');
      return;
    }

    final int status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      yield ChatDeltaError(_errorForStatus(status));
      return;
    }

    final ResponseBody? body = response.data;
    if (body == null) {
      yield const ChatDeltaError('chat returned an empty response body');
      return;
    }

    // Buffer raw bytes (not decoded text) so a multi-byte UTF-8 sequence
    // split across two reads isn't mangled — mirrors the shim backend's
    // framing (the coach echoes em-dashes / smart quotes).
    final List<int> rawBuffer = <int>[];
    try {
      await for (final Uint8List bytes in body.stream) {
        rawBuffer.addAll(bytes);
        while (true) {
          final int sep = _indexOfDoubleNewline(rawBuffer);
          if (sep == -1) break;
          final List<int> eventBytes = rawBuffer.sublist(0, sep);
          rawBuffer.removeRange(0, sep + _eventBoundaryLength(rawBuffer, sep));
          for (final ChatDelta d in _deltasFromBlock(utf8.decode(eventBytes))) {
            yield d;
            if (d is ChatDeltaError) return;
          }
        }
      }
      // The final flush may omit the closing `\n\n`; drain the remainder.
      if (rawBuffer.isNotEmpty) {
        for (final ChatDelta d in _deltasFromBlock(utf8.decode(rawBuffer))) {
          yield d;
          if (d is ChatDeltaError) return;
        }
      }
    } catch (e) {
      yield ChatDeltaError('chat stream read failed: $e');
    }
  }

  /// Internal error markers (folded into `[chat error: …]` and shown to
  /// the caregiver as [chatFriendlyErrorMessage], never verbatim). The
  /// status is kept for the stored body so logs/diagnostics can tell a
  /// quota (429) from a capacity stop (503) from auth (401).
  static String _errorForStatus(int status) {
    switch (status) {
      case 401:
        return 'chat auth rejected (401)';
      case 413:
        return 'chat prompt too large (413)';
      case 429:
        return 'chat daily limit reached (429)';
      case 503:
        return 'chat capacity reached (503)';
      default:
        return 'chat backend error ($status)';
    }
  }

  /// Parse one `\n\n`-delimited block of `data:` lines from the Worker's
  /// vendor-neutral stream. `{"text":"…"}` → [ChatDeltaText];
  /// `{"error":"…"}` → [ChatDeltaError]; `[DONE]` and anything unparseable
  /// → nothing.
  static Iterable<ChatDelta> _deltasFromBlock(String block) sync* {
    for (final String rawLine in block.split('\n')) {
      final String line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      if (!line.startsWith('data:')) continue;
      final String payload = line.substring(5).startsWith(' ')
          ? line.substring(6)
          : line.substring(5);
      if (payload == '[DONE]') continue;
      final dynamic obj;
      try {
        obj = json.decode(payload);
      } on FormatException {
        continue;
      }
      if (obj is! Map<String, dynamic>) continue;
      if (obj['error'] is String) {
        yield ChatDeltaError(obj['error'] as String);
        continue;
      }
      final dynamic text = obj['text'];
      if (text is String && text.isNotEmpty) {
        yield ChatDeltaText(text);
      }
    }
  }

  // Byte-level SSE framing, mirroring ClaudeShimChatBackend's private
  // helpers (kept self-contained so the shim file stays untouched).
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

  static int _eventBoundaryLength(List<int> bytes, int sep) =>
      bytes[sep + 1] == 0x0A ? 2 : 3;
}

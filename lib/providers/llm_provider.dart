import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../seed/activity_summary_prompt.dart';

part 'llm_provider.g.dart';

/// Which surface a [ActivityEvent] in the "catch me up" feed came from
/// (Phase 14.12). Mirrors `RecentActivityOrigin` but lives here because
/// the LLM call surface (not the Recent Activity card) owns the shape it
/// passes to [LLMProvider.generateActivitySummary]. [handoff] is the
/// care-team shift-handoff source that joins when Phase 14.32 lands;
/// nothing emits one in v1.
enum ActivityEventKind { journal, dose, appointment, handoff }

/// One thing that happened in the caregiver's last 24 hours, flattened to
/// the narrow slice [LLMProvider.generateActivitySummary] needs (Phase
/// 14.12).
///
/// Kept deliberately small — a [kind], a one-line [summary] already in the
/// app's own voice, and the [occurredAt] timestamp. The model never sees
/// raw rows; it gets this pre-summarized list so the prompt stays short
/// and free of anything resembling a diagnosis. [cacheToken] is the stable
/// per-event string the card hashes into its 30-minute cache key, so the
/// same set of events reopens to the same cached summary.
@immutable
class ActivityEvent {
  const ActivityEvent({
    required this.kind,
    required this.summary,
    required this.occurredAt,
  });

  final ActivityEventKind kind;
  final String summary;
  final DateTime occurredAt;

  /// Canonical, order-stable string used to fingerprint the event for the
  /// Home card's cache key. UTC-normalized so a host timezone shift can't
  /// silently bust the cache.
  String get cacheToken =>
      '${kind.name}|${occurredAt.toUtc().toIso8601String()}|$summary';

  @override
  bool operator ==(Object other) =>
      other is ActivityEvent &&
      other.kind == kind &&
      other.summary == summary &&
      other.occurredAt == occurredAt;

  @override
  int get hashCode => Object.hash(kind, summary, occurredAt);
}

/// Backend for the Home "catch me up" recap LLM call (Phase 14.12).
///
/// Two v1 implementations: [FakeLLMProvider] (canned + streamed for tests
/// and the demo tour) and [ClaudeCLIProvider] (HTTP shim — POSTs to
/// `tools/claude_shim.py` on `localhost:8765`). The app never imports
/// either concrete class directly; it goes through [llmProvider] which
/// picks based on `USE_FAKE_LLM`.
abstract class LLMProvider {
  /// Stream a single-paragraph, plain-language recap of the caregiver's
  /// last [lastNHours] of [events] for the Home "catch me up" card
  /// (Phase 14.12).
  ///
  /// Each yielded string is the growing accumulated paragraph (word by
  /// word as bytes arrive); the last value is the whole summary and the
  /// stream then closes. The recap is a warm, factual recap of what
  /// happened — never a clinical assessment or a suggested treatment plan.
  Stream<String> generateActivitySummary({
    int lastNHours,
    required List<ActivityEvent> events,
  });
}

/// In-memory provider that streams a hand-authored canned recap
/// (BUILD_SPEC.md §6.1 + §10.2).
///
/// Streams the response in [chunkSize]-token slices with [delay] between
/// each. Used by `test/` widget tests and by the demo tour — never live
/// in real-user app runs.
class FakeLLMProvider implements LLMProvider {
  const FakeLLMProvider({
    this.chunkSize = 8,
    this.delay = const Duration(milliseconds: 60),
  });

  /// Tokens per partial chunk (BUILD_SPEC.md §6.1 — fake streams in
  /// 8-token chunks).
  final int chunkSize;

  /// Inter-chunk delay (BUILD_SPEC.md §6.1 — 60ms between chunks).
  final Duration delay;

  @override
  Stream<String> generateActivitySummary({
    int lastNHours = 24,
    required List<ActivityEvent> events,
  }) async* {
    // Deterministic canned recap (BUILD_SPEC.md §6.1 — the fake never
    // calls out). Streams the hand-authored paragraph in the same
    // [chunkSize]-token slices the real path uses so the Home card shows
    // the same word-by-word fade-in in the demo.
    final List<String> tokens = _tokenize(fakeActivitySummary);
    final StringBuffer buffer = StringBuffer();
    if (tokens.isEmpty) {
      yield '';
      return;
    }
    for (int i = 0; i < tokens.length; i += chunkSize) {
      final int end =
          (i + chunkSize) > tokens.length ? tokens.length : (i + chunkSize);
      for (int j = i; j < end; j++) {
        buffer.write(tokens[j]);
      }
      yield buffer.toString();
      if (end < tokens.length) {
        await Future<void>.delayed(delay);
      }
    }
  }

  /// Tokenize on whitespace boundaries, keeping both the whitespace and
  /// non-whitespace runs so the accumulated buffer reconstructs the
  /// original string exactly.
  static List<String> _tokenize(String text) {
    final RegExp re = RegExp(r'\s+|\S+');
    return re.allMatches(text).map((Match m) => m.group(0)!).toList();
  }
}

/// Base URL of the LLM shim (BUILD_SPEC.md §8 — `tools/claude_shim.py`).
/// Defaults to the local dev shim on `127.0.0.1:8765`; override for a
/// remote test server (e.g. a No-IP host this Mac forwards to) with
/// `--dart-define=SHIM_URL=http://<host>:<port>`. Production goes through
/// the deferred [ClaudeAPIProvider], not this.
const String shimBaseUrl =
    String.fromEnvironment('SHIM_URL', defaultValue: 'http://localhost:8765');

/// The `/generate` endpoint, built from [shimBaseUrl].
const String claudeShimEndpoint = '$shimBaseUrl/generate';

/// Shared secret the shim requires when it's exposed beyond localhost.
/// Empty (no auth) for local dev. When set via
/// `--dart-define=SHIM_TOKEN=<secret>`, every shim request carries
/// `Authorization: Bearer <token>` so a public host isn't an open door to
/// the operator's Claude subscription. Baked into the build — extractable
/// from the binary, so it deters drive-by abuse, not a determined attacker.
const String shimToken = String.fromEnvironment('SHIM_TOKEN', defaultValue: '');

/// `Authorization` header for shim requests, or an empty map when no
/// [shimToken] is configured. Shared by the recap + chat backends.
Map<String, String> shimAuthHeaders() =>
    shimToken.isEmpty ? const <String, String>{} : <String, String>{
      'Authorization': 'Bearer $shimToken',
    };

/// Bounded [Dio] for shim calls — a bare `Dio()` has NO timeouts, so a
/// hung shim / dropped Funnel mid-stream would strand the recap, chat,
/// or voice intent awaiting forever (bad for an app whose core promise
/// is "what do I do RIGHT NOW"). For `ResponseType.stream` requests Dio
/// applies `receiveTimeout` between chunks, so the generous 120s bounds
/// a stall without cutting off a long, healthy generation. Shared by the
/// recap + chat backends.
Dio buildShimDio() => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 120),
    ));

/// Real, shim-backed provider (BUILD_SPEC.md §6.1).
///
/// POSTs `{system, user}` to [claudeShimEndpoint], consumes the SSE
/// stream the shim forwards from `claude --print --output-format
/// stream-json`, extracts text from each `assistant` event, and yields
/// the growing accumulated paragraph for the Home "catch me up" recap.
class ClaudeCLIProvider implements LLMProvider {
  const ClaudeCLIProvider({
    Dio? dio,
    this.endpoint = claudeShimEndpoint,
  }) : _injectedDio = dio;

  /// Injected for tests — production constructs a fresh [Dio] per
  /// request so the riverpod provider can stay `const`.
  final Dio? _injectedDio;

  /// Override only for integration tests that pin a different port.
  final String endpoint;

  @override
  Stream<String> generateActivitySummary({
    int lastNHours = 24,
    required List<ActivityEvent> events,
  }) async* {
    // Nothing to recap — don't burn a generation. The Home card already
    // guards empty days; a direct caller gets the same empty result its
    // consumers collapse on.
    if (events.isEmpty) {
      yield '';
      return;
    }

    final Dio dio = _injectedDio ?? buildShimDio();
    final String userMessage = buildActivityUserMessage(
      lastNHours: lastNHours,
      events: events,
    );

    Response<ResponseBody> response;
    try {
      response = await dio.post<ResponseBody>(
        endpoint,
        data: <String, String>{
          'system': activitySummarySystemPrompt,
          'user': userMessage,
        },
        options: Options(
          responseType: ResponseType.stream,
          contentType: Headers.jsonContentType,
          headers: shimAuthHeaders(),
        ),
      );
    } catch (e) {
      // Surfaces through the card's AsyncValue.guard to the muted
      // "couldn't put together your recap" line — Home never red-boxes.
      throw Exception('summary request failed: $e');
    }

    final ResponseBody? body = response.data;
    if (body == null) {
      throw Exception('shim returned an empty summary response body');
    }

    // The recap is plain prose — accumulate the text deltas and yield the
    // growing paragraph, the same word-by-word contract the fake uses so
    // the card streams identically in either mode.
    final StringBuffer accumulated = StringBuffer();
    await for (final String delta in _streamTextDeltas(body)) {
      accumulated.write(delta);
      yield accumulated.toString();
    }
  }

  /// Flatten the last [lastNHours] of [events] into the `user` body for
  /// [generateActivitySummary]. One line per event, oldest first (the card
  /// pre-sorts ascending), tagged with a coarse part-of-day so the model
  /// can phrase "this morning / this evening" without raw timestamps.
  static String buildActivityUserMessage({
    required int lastNHours,
    required List<ActivityEvent> events,
  }) {
    final StringBuffer sb = StringBuffer()
      ..writeln('window_hours: $lastNHours')
      ..writeln('events (oldest first):');
    for (final ActivityEvent e in events) {
      sb.writeln(
          '- ${_timeOfDay(e.occurredAt)} · [${e.kind.name}] ${e.summary}');
    }
    return sb.toString().trimRight();
  }

  /// Coarse part-of-day label for [t] — enough for a recap to read
  /// naturally without handing the model an exact clock time.
  static String _timeOfDay(DateTime t) {
    final int h = t.hour;
    if (h < 12) return 'morning';
    if (h < 17) return 'afternoon';
    if (h < 21) return 'evening';
    return 'night';
  }

  /// Stream the text deltas from a shim SSE [body], throwing on a shim
  /// `{"error": ...}` event.
  static Stream<String> _streamTextDeltas(ResponseBody body) async* {
    final List<int> rawBuffer = <int>[];
    await for (final Uint8List bytes in body.stream) {
      rawBuffer.addAll(bytes);
      while (true) {
        final int sep = _indexOfDoubleNewline(rawBuffer);
        if (sep == -1) break;
        final List<int> eventBytes = rawBuffer.sublist(0, sep);
        rawBuffer.removeRange(0, sep + _eventBoundaryLength(rawBuffer, sep));
        yield* _deltasFromEvent(utf8.decode(eventBytes));
      }
    }
    // Trailing event the shim may flush without the closing `\n\n`.
    if (rawBuffer.isNotEmpty) {
      yield* _deltasFromEvent(utf8.decode(rawBuffer));
    }
  }

  /// Extract text deltas from one raw SSE event block — skips non-`data:`
  /// lines and the `[DONE]` terminator, throws on a shim error payload.
  static Stream<String> _deltasFromEvent(String event) async* {
    for (final String rawLine in event.split('\n')) {
      // CRLF tolerance: strip a trailing \r left by \r\n events.
      final String line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      if (!line.startsWith('data:')) continue;
      final String payload = line.substring(5).startsWith(' ')
          ? line.substring(6)
          : line.substring(5);
      if (payload == '[DONE]') continue;
      final _EventPayload parsed = _parseEvent(payload);
      if (parsed.error != null) {
        throw Exception('summary generation failed: ${parsed.error}');
      }
      final String? text = parsed.text;
      if (text != null && text.isNotEmpty) yield text;
    }
  }

  /// Index of the first `\n\n` (0x0A 0x0A) byte pair in [bytes], or
  /// -1 if no event boundary has arrived yet.
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

  /// Extract a text delta (or error) from one SSE event payload. The
  /// shim forwards `claude --print --output-format stream-json` events
  /// untouched; we only care about the `assistant` (text content) and
  /// `error` shapes — the `system` init line and `user` echo are no-ops.
  static _EventPayload _parseEvent(String payload) {
    final dynamic obj;
    try {
      obj = json.decode(payload);
    } on FormatException {
      return const _EventPayload();
    }
    if (obj is! Map<String, dynamic>) return const _EventPayload();

    if (obj['error'] is String) {
      return _EventPayload(error: obj['error'] as String);
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
          return _EventPayload(text: sb.toString());
        }
      }
    }
    return const _EventPayload();
  }
}

/// Parsed shape of one SSE event payload. Either carries a text delta
/// to append to the accumulator, an error to surface, or neither (a
/// `system` init line, a `[DONE]` terminator we've already filtered,
/// etc.).
class _EventPayload {
  const _EventPayload({this.text, this.error});
  final String? text;
  final String? error;
}

/// Build-time flag (BUILD_SPEC.md §1 — `USE_FAKE_LLM`).
///
/// **Real engine by default.** A shipped/run build uses the live,
/// shim-backed [ClaudeCLIProvider] for the Home catch-me-up recap — there
/// is no fake in a real run. The one exception is `flutter test`, where
/// the default flips to [FakeLLMProvider] so widget/golden tests never hit
/// the network (a test can still override `llmProvider`, and most do). An
/// explicit `--dart-define=USE_FAKE_LLM=true|false` always wins over both.
bool get _useFakeLLM {
  if (const bool.hasEnvironment('USE_FAKE_LLM')) {
    return const bool.fromEnvironment('USE_FAKE_LLM');
  }
  return _isUnderFlutterTest;
}

/// True only when running under `flutter test` (the harness exports
/// `FLUTTER_TEST`). Any lookup failure falls back to false — the real
/// engine — so a real device never silently runs the fake.
bool get _isUnderFlutterTest {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}

/// Public view of the fake-engine selection for SIBLING backends — the
/// chat/voice backend keys off the same rule so a `USE_FAKE_LLM=true`
/// demo build (and every `flutter test` run) is deterministic across the
/// recap AND chat (2026-06-11; previously a DEMO_MODE run's chat still hit
/// the live shim).
bool get useFakeLLMEngine => _useFakeLLM;

/// Riverpod-wired backend selection. Widgets and services read
/// `ref.watch(llmProvider)` and get whichever impl the build mode
/// picked — they never see the concrete class.
@Riverpod(keepAlive: true)
LLMProvider llm(Ref ref) =>
    _useFakeLLM ? const FakeLLMProvider() : const ClaudeCLIProvider();

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/behavior.dart';
import '../models/decoder_result.dart';
import '../models/triage.dart';
import '../seed/activity_summary_prompt.dart';
import '../seed/fake_llm_seeds.dart';
import '../seed/system_prompt.dart';

part 'llm_provider.freezed.dart';
part 'llm_provider.g.dart';

/// One token in a decoder script stream (BUILD_SPEC.md §6.1 + §7.3).
///
/// The shim's SSE chunks accumulate text bytes; [DecoderChunk.partial]
/// carries the growing JSON string so the decoder result screen can
/// render the word-by-word fade-in. [DecoderChunk.done] is the terminal
/// success chunk — its [DecoderResult] is the parsed, validated whole.
/// [DecoderChunk.error] terminates the stream on parse failure or
/// transport error.
@freezed
sealed class DecoderChunk with _$DecoderChunk {
  const factory DecoderChunk.partial({
    required String accumulatedJson,
  }) = DecoderChunkPartial;

  const factory DecoderChunk.done({
    required DecoderResult result,
  }) = DecoderChunkDone;

  const factory DecoderChunk.error({
    required String message,
  }) = DecoderChunkError;
}

/// The slice of [Patient] the LLM call actually needs
/// (BUILD_SPEC.md §7.2).
///
/// Kept narrow on purpose: the system prompt forbids diagnosis claims
/// and prognosis statements, so we only pass the two facts the user
/// message template requires (stage + age). Everything else about the
/// patient lives in `models/patient.dart` and is used by the crisis
/// card, journal, etc. — not the LLM.
@freezed
abstract class PatientContext with _$PatientContext {
  const factory PatientContext({
    required String stage,
    required int age,
  }) = _PatientContext;
}

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

/// Backend for the decoder LLM call (BUILD_SPEC.md §6.1).
///
/// Two v1 implementations: [FakeLLMProvider] (canned + streamed for
/// tests and the demo tour) and [ClaudeCLIProvider] (HTTP shim — POSTs
/// to `tools/claude_shim.py` on `localhost:8765`). The app never
/// imports either concrete class directly; it goes through
/// [llmProvider] which picks based on `USE_FAKE_LLM`.
abstract class LLMProvider {
  /// Stream the decoder script for [behavior] + [triage]. Yields
  /// incremental [DecoderChunk]s as text arrives; terminates with
  /// either [DecoderChunk.done] or [DecoderChunk.error].
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  });

  /// Stream a single-paragraph, plain-language recap of the caregiver's
  /// last [lastNHours] of [events] for the Home "catch me up" card
  /// (Phase 14.12).
  ///
  /// Each yielded string is the growing accumulated paragraph (the same
  /// word-by-word contract the decoder uses); the last value is the whole
  /// summary and the stream then closes. The recap is a warm, factual
  /// recap of what happened — never a clinical assessment or a suggested
  /// treatment plan.
  Stream<String> generateActivitySummary({
    int lastNHours,
    required List<ActivityEvent> events,
  });
}

/// In-memory provider that streams hand-authored canned responses
/// from [fakeLLMSeeds] (BUILD_SPEC.md §6.1 + §10.2).
///
/// Streams the response JSON in [chunkSize]-token slices with [delay]
/// between each, then emits [DecoderChunk.done] with the parsed
/// [DecoderResult]. Used by `test/` widget tests and by the demo tour
/// — never live in real-user app runs.
class FakeLLMProvider implements LLMProvider {
  const FakeLLMProvider({
    this.chunkSize = 8,
    this.delay = const Duration(milliseconds: 60),
    this.clock = _defaultClock,
  });

  /// Tokens per partial chunk (BUILD_SPEC.md §6.1 — fake streams in
  /// 8-token chunks).
  final int chunkSize;

  /// Inter-chunk delay (BUILD_SPEC.md §6.1 — 60ms between chunks).
  final Duration delay;

  /// Injectable clock so tests can pin `generatedAt` deterministically.
  final DateTime Function() clock;

  static DateTime _defaultClock() => DateTime.now();

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    final DecoderResult canned =
        fakeLLMSeeds[behavior.id] ?? _freeTextFallback();
    final DecoderResult stamped = canned.copyWith(generatedAt: clock());

    // Serialize without `generated_at` — the LLM doesn't emit that
    // field in real output (it's set client-side at parse-done), so
    // the streamed JSON the fake produces matches the shape of real
    // shim responses.
    final Map<String, dynamic> jsonShape = stamped.toJson()
      ..remove('generatedAt')
      ..remove('generated_at');
    final String fullJson =
        const JsonEncoder.withIndent('  ').convert(jsonShape);

    final List<String> tokens = _tokenize(fullJson);
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < tokens.length; i += chunkSize) {
      final int end = (i + chunkSize) > tokens.length
          ? tokens.length
          : (i + chunkSize);
      for (int j = i; j < end; j++) {
        buffer.write(tokens[j]);
      }
      yield DecoderChunk.partial(accumulatedJson: buffer.toString());
      if (end < tokens.length) {
        await Future<void>.delayed(delay);
      }
    }
    yield DecoderChunk.done(result: stamped);
  }

  @override
  Stream<String> generateActivitySummary({
    int lastNHours = 24,
    required List<ActivityEvent> events,
  }) async* {
    // Deterministic canned recap (BUILD_SPEC.md §6.1 — the fake never
    // calls out). Streams the hand-authored paragraph in the same
    // [chunkSize]-token slices the decoder uses so the Home card shows
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

  /// Soft, generic Natali-voice script for the free-text "Something
  /// else — describe it" path (BUILD_SPEC.md §5.2). Keeps the demo
  /// alive when the picker routes a behavior id outside the canonical
  /// 8 without falling back to a crash.
  DecoderResult _freeTextFallback() {
    return DecoderResult(
      say: const <String>[
        "I'm right here with you. You're not alone in this moment.",
        "Let's take a slow breath together — there's no rush.",
        'Tell me what would feel a little better right now.',
      ],
      tweak: const <String>[
        'Lower your voice and slow your pace. Sit beside them at eye level — small physical alignments calm the room.',
      ],
      dontSay: const <String>[
        "Don't try to argue the facts or explain the situation. Comfort first; logic almost never lands in the moment.",
      ],
      generatedAt: clock(),
    );
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
/// [shimToken] is configured. Shared by the decoder + chat backends.
Map<String, String> shimAuthHeaders() =>
    shimToken.isEmpty ? const <String, String>{} : <String, String>{
      'Authorization': 'Bearer $shimToken',
    };

/// Real, shim-backed provider (BUILD_SPEC.md §6.1 + §7.3).
///
/// POSTs `{system, user}` to [claudeShimEndpoint], consumes the SSE
/// stream the shim forwards from `claude --print --output-format
/// stream-json`, extracts text from each `assistant` event, accumulates
/// the JSON the model emits, and yields [DecoderChunk]s:
///
/// - [DecoderChunk.partial] after every event with new text — the
///   accumulated string may be partial-but-growing JSON; the decoder
///   result screen renders it word-by-word as bytes arrive.
/// - [DecoderChunk.done] once the accumulated buffer parses cleanly
///   (the parser is run on every partial so the first successful parse
///   wins — `stream-json` from claude code often emits one final
///   `assistant` snapshot that completes the JSON in a single chunk).
/// - [DecoderChunk.error] on transport failure, an `{"error": ...}`
///   event from the shim, or a parse failure at end-of-stream.
class ClaudeCLIProvider implements LLMProvider {
  const ClaudeCLIProvider({
    Dio? dio,
    this.endpoint = claudeShimEndpoint,
    this.clock = _defaultClock,
  }) : _injectedDio = dio;

  /// Injected for tests — production constructs a fresh [Dio] per
  /// request so the riverpod provider can stay `const`.
  final Dio? _injectedDio;

  /// Override only for integration tests that pin a different port.
  final String endpoint;

  /// Wall clock stamped onto [DecoderResult.generatedAt] when the
  /// accumulated JSON parses. Injectable so tests can pin a fixed time.
  final DateTime Function() clock;

  static DateTime _defaultClock() => DateTime.now();

  /// Build the user-message body per BUILD_SPEC.md §7.2. Canonical
  /// behaviors emit `behavior: <label>`; anything outside
  /// [Behavior.canonical] is treated as a free-text "Something else"
  /// description and emits `behavior_freetext: <label>` instead.
  ///
  /// The label maps for the triage enums match the lowercase forms in
  /// the §7.1 example input (`when: late afternoon / evening`,
  /// `what_tried: tried to explain`, etc.) so the few-shot example
  /// pins to the same vocabulary the live calls use.
  static String buildUserMessage({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) {
    final bool isCanonical = Behavior.byId(behavior.id) != null;
    final String behaviorLine = isCanonical
        ? 'behavior: ${behavior.label}'
        : 'behavior_freetext: ${behavior.label}';
    return <String>[
      behaviorLine,
      'when: ${_whenLabel(triage.when)}',
      'what_changed: ${_whatChangedLabel(triage.whatChanged)}',
      'what_tried: ${_whatTriedLabel(triage.whatTried)}',
      'attempt: $attempt',
      'patient_context: ${patient.stage}, age ${patient.age}',
    ].join('\n');
  }

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) async* {
    final Dio dio = _injectedDio ?? Dio();
    final String userMessage = buildUserMessage(
      behavior: behavior,
      triage: triage,
      patient: patient,
      attempt: attempt,
    );

    Response<ResponseBody> response;
    try {
      response = await dio.post<ResponseBody>(
        endpoint,
        data: <String, String>{
          'system': claudeSystemPrompt,
          'user': userMessage,
        },
        options: Options(
          responseType: ResponseType.stream,
          contentType: Headers.jsonContentType,
          headers: shimAuthHeaders(),
        ),
      );
    } catch (e) {
      yield DecoderChunk.error(message: 'shim request failed: $e');
      return;
    }

    final ResponseBody? body = response.data;
    if (body == null) {
      yield const DecoderChunk.error(
        message: 'shim returned an empty response body',
      );
      return;
    }

    final StringBuffer accumulated = StringBuffer();
    DecoderResult? completed;
    // Buffer raw bytes (not decoded text) so a multi-byte UTF-8
    // sequence split across two `Uint8List` reads doesn't get mangled
    // into a replacement char — the system prompt's voice includes
    // em-dashes and smart quotes, which the model echoes back.
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

          for (final String line in event.split('\n')) {
            if (!line.startsWith('data:')) continue;
            // `data:`/`data: ` — strip the prefix + optional space.
            final String payload =
                line.substring(5).startsWith(' ')
                    ? line.substring(6)
                    : line.substring(5);
            if (payload == '[DONE]') continue;

            final _EventPayload parsed = _parseEvent(payload);
            if (parsed.error != null) {
              yield DecoderChunk.error(message: parsed.error!);
              return;
            }
            if (parsed.text == null || parsed.text!.isEmpty) continue;

            accumulated.write(parsed.text);
            final String snapshot = accumulated.toString();
            yield DecoderChunk.partial(accumulatedJson: snapshot);

            // Tolerant parse attempt — partial JSON throws
            // [FormatException]; the first chunk that parses
            // cleanly is the completed result. Once we have one,
            // subsequent events can't unwind it (the model only
            // ever appends text).
            completed ??= _tryParse(snapshot);
          }
        }
      }
      // The shim's final flush may omit the closing `\n\n` if the
      // process exits cleanly; treat any trailing partial event the
      // same way as a fully-terminated one.
      if (rawBuffer.isNotEmpty) {
        final String trailing = utf8.decode(rawBuffer);
        rawBuffer.clear();
        for (final String line in trailing.split('\n')) {
          if (!line.startsWith('data:')) continue;
          final String payload =
              line.substring(5).startsWith(' ')
                  ? line.substring(6)
                  : line.substring(5);
          if (payload == '[DONE]') continue;
          final _EventPayload parsed = _parseEvent(payload);
          if (parsed.error != null) {
            yield DecoderChunk.error(message: parsed.error!);
            return;
          }
          if (parsed.text == null || parsed.text!.isEmpty) continue;
          accumulated.write(parsed.text);
          final String snapshot = accumulated.toString();
          yield DecoderChunk.partial(accumulatedJson: snapshot);
          completed ??= _tryParse(snapshot);
        }
      }
    } catch (e) {
      yield DecoderChunk.error(message: 'stream read failed: $e');
      return;
    }

    if (completed != null) {
      yield DecoderChunk.done(result: completed);
      return;
    }

    // Last-ditch parse on whatever we accumulated. Empty buffer → no
    // text ever arrived; otherwise we hand the FormatException's
    // message back so the caller can surface it.
    final String rawFinal = accumulated.toString().trim();
    if (rawFinal.isEmpty) {
      yield const DecoderChunk.error(
        message: 'shim stream closed without emitting any script text',
      );
      return;
    }
    try {
      final dynamic parsed = json.decode(_extractJsonObject(rawFinal));
      if (parsed is! Map<String, dynamic>) {
        yield const DecoderChunk.error(
          message: 'decoder output was not a JSON object',
        );
        return;
      }
      yield DecoderChunk.done(result: _toResult(parsed));
    } on FormatException catch (e) {
      yield DecoderChunk.error(message: 'decoder JSON parse failed: ${e.message}');
    }
  }

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

    final Dio dio = _injectedDio ?? Dio();
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

    // The recap is plain prose, not JSON — accumulate the text deltas and
    // yield the growing paragraph, the same word-by-word contract the fake
    // and the decoder use so the card streams identically in either mode.
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
  /// `{"error": ...}` event. Shared SSE framing for the prose summary
  /// path; [generateDecoderScript] inlines its own loop because it
  /// re-parses the accumulated JSON after every delta.
  static Stream<String> _streamTextDeltas(ResponseBody body) async* {
    final List<int> rawBuffer = <int>[];
    await for (final Uint8List bytes in body.stream) {
      rawBuffer.addAll(bytes);
      while (true) {
        final int sep = _indexOfDoubleNewline(rawBuffer);
        if (sep == -1) break;
        final List<int> eventBytes = rawBuffer.sublist(0, sep);
        rawBuffer.removeRange(0, sep + 2);
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
    for (final String line in event.split('\n')) {
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

  /// Pull the JSON object out of [text], tolerating a Markdown code fence
  /// (or stray pre/postamble) the live model sometimes wraps the result in
  /// despite the "ONLY valid JSON" instruction. Returns the substring from
  /// the first `{` to the last `}`; with no brace pair yet (still
  /// streaming) the trimmed text is returned unchanged so the tolerant
  /// parse simply fails and waits for more.
  static String _extractJsonObject(String text) {
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start == -1 || end == -1 || end < start) return text.trim();
    return text.substring(start, end + 1);
  }

  /// Try parsing [text] as a [DecoderResult]. Returns null if the JSON
  /// is partial (still growing) or doesn't yet contain the required
  /// `say`/`tweak`/`dont_say` keys.
  DecoderResult? _tryParse(String text) {
    try {
      final dynamic parsed = json.decode(_extractJsonObject(text));
      if (parsed is! Map<String, dynamic>) return null;
      if (parsed['say'] is! List ||
          parsed['tweak'] is! List ||
          parsed['dont_say'] is! List) {
        return null;
      }
      return _toResult(parsed);
    } on FormatException {
      return null;
    }
  }

  DecoderResult _toResult(Map<String, dynamic> parsed) {
    final List<String> say = _stringList(parsed['say']);
    final List<String> tweak = _stringList(parsed['tweak']);
    final List<String> dontSay = _stringList(parsed['dont_say']);
    return DecoderResult(
      say: say,
      tweak: tweak,
      dontSay: dontSay,
      generatedAt: clock(),
    );
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const <String>[];
    return raw.map((dynamic e) => e.toString()).toList(growable: false);
  }

  /// Index of the first `\n\n` (0x0A 0x0A) byte pair in [bytes], or
  /// -1 if no event boundary has arrived yet.
  static int _indexOfDoubleNewline(List<int> bytes) {
    for (int i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0x0A && bytes[i + 1] == 0x0A) return i;
    }
    return -1;
  }

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

/// Lowercase, human-readable form of [TriageWhen], matching the
/// example input format in BUILD_SPEC.md §7.1.
String _whenLabel(TriageWhen? w) {
  if (w == null) return 'unknown';
  switch (w) {
    case TriageWhen.morning:
      return 'morning';
    case TriageWhen.afternoon:
      return 'afternoon';
    case TriageWhen.lateAfternoonEvening:
      return 'late afternoon / evening';
    case TriageWhen.night:
      return 'night';
    case TriageWhen.justStarted:
      return "just started — don't know yet";
  }
}

String _whatChangedLabel(TriageWhatChanged? w) {
  if (w == null) return 'unknown';
  switch (w) {
    case TriageWhatChanged.nothing:
      return 'nothing';
    case TriageWhatChanged.schedule:
      return 'schedule';
    case TriageWhatChanged.medication:
      return 'medication';
    case TriageWhatChanged.health:
      return 'health (UTI, illness)';
    case TriageWhatChanged.environment:
      return 'environment (new place, visitors)';
    case TriageWhatChanged.dontKnow:
      return "don't know";
  }
}

String _whatTriedLabel(TriageWhatTried? w) {
  if (w == null) return 'unknown';
  switch (w) {
    case TriageWhatTried.talked:
      return 'talked to them about it';
    case TriageWhatTried.triedToExplain:
      return 'tried to explain';
    case TriageWhatTried.walkedAway:
      return 'walked away';
    case TriageWhatTried.distracted:
      return 'distracted them';
    case TriageWhatTried.nothingYet:
      return 'nothing yet — just started';
  }
}

/// Build-time flag (BUILD_SPEC.md §1 — `USE_FAKE_LLM`).
///
/// **Real engine by default.** A shipped/run build uses the live,
/// shim-backed [ClaudeCLIProvider] for the decoder AND the Home
/// catch-me-up recap — there is no fake in a real run. The one exception
/// is `flutter test`, where the default flips to [FakeLLMProvider] so
/// widget/golden tests never hit the network (a test can still override
/// `llmProvider`, and most do). An explicit
/// `--dart-define=USE_FAKE_LLM=true|false` always wins over both.
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

/// Riverpod-wired backend selection. Widgets and services read
/// `ref.watch(llmProvider)` and get whichever impl the build mode
/// picked — they never see the concrete class.
@Riverpod(keepAlive: true)
LLMProvider llm(Ref ref) =>
    _useFakeLLM ? const FakeLLMProvider() : const ClaudeCLIProvider();

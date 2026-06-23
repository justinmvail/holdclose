import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:holdclose/providers/llm_provider.dart';
import 'package:holdclose/seed/activity_summary_prompt.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

void main() {
  // Use a zero delay so the test suite stays fast — the streaming
  // semantics (chunk count + content) are independent of wall-clock
  // delay, and the production constructor defaults to 60ms.
  FakeLLMProvider buildFake() => const FakeLLMProvider(delay: Duration.zero);

  group('FakeLLMProvider — generateActivitySummary (Phase 14.12)', () {
    final List<ActivityEvent> events = <ActivityEvent>[
      ActivityEvent(
        kind: ActivityEventKind.journal,
        summary: 'Restless before dinner',
        occurredAt: DateTime.utc(2026, 6, 1, 17, 30),
      ),
      ActivityEvent(
        kind: ActivityEventKind.dose,
        summary: 'Gave Donepezil 10 mg',
        occurredAt: DateTime.utc(2026, 6, 1, 19),
      ),
    ];

    test('streams accumulations terminating in the canned summary',
        () async {
      final FakeLLMProvider fake = buildFake();
      final List<String> accumulations = await fake
          .generateActivitySummary(lastNHours: 24, events: events)
          .toList();

      expect(accumulations, isNotEmpty);
      // The last accumulation is the whole canned paragraph.
      expect(accumulations.last, fakeActivitySummary);
    });

    test('accumulations grow monotonically toward the full paragraph',
        () async {
      final FakeLLMProvider fake = buildFake();
      final List<String> accumulations = await fake
          .generateActivitySummary(events: events)
          .toList();

      for (int i = 1; i < accumulations.length; i++) {
        expect(accumulations[i].startsWith(accumulations[i - 1]), isTrue,
            reason: 'accumulation #$i is not a prefix-superset of #${i - 1}');
        expect(accumulations[i].length,
            greaterThan(accumulations[i - 1].length));
      }
    });

    test('the canned recap stays warm and non-clinical', () {
      // Scope guardrail: a recap, never a diagnosis or treatment plan, and
      // the brand voice carries no exclamation marks (BUILD_SPEC.md §3.3).
      expect(fakeActivitySummary, isNot(contains('!')));
      expect(fakeActivitySummary.toLowerCase(), isNot(contains('diagnos')));
      expect(fakeActivitySummary.toLowerCase(), isNot(contains('prescrib')));
      expect(fakeActivitySummary, contains('your loved one'));
    });
  });

  group('ClaudeCLIProvider — generateActivitySummary (live shim)', () {
    final List<ActivityEvent> events = <ActivityEvent>[
      ActivityEvent(
        kind: ActivityEventKind.journal,
        summary: 'Mom got upset before dinner',
        occurredAt: DateTime.utc(2026, 6, 1, 17, 30),
      ),
      ActivityEvent(
        kind: ActivityEventKind.dose,
        summary: 'Gave Donepezil 10 mg',
        occurredAt: DateTime.utc(2026, 6, 1, 19),
      ),
    ];

    test('empty events yield one empty string without calling out',
        () async {
      // The throwing adapter proves no request is attempted on an empty day.
      final _ThrowingAdapter adapter = _ThrowingAdapter();
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(dio: dio);
      final List<String> out = await provider
          .generateActivitySummary(events: const <ActivityEvent>[])
          .toList();
      expect(out, <String>['']);
    });

    test('streams growing accumulations ending in the full paragraph',
        () async {
      const String a = 'Over the last day, things were steady.';
      const String b = ' The evening dose went down without a fuss.';
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _assistantEvent(a),
        _assistantEvent(b),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(dio: dio);

      final List<String> out = await provider
          .generateActivitySummary(lastNHours: 24, events: events)
          .toList();

      expect(out, <String>[a, a + b]);
      for (int i = 1; i < out.length; i++) {
        expect(out[i].startsWith(out[i - 1]), isTrue);
        expect(out[i].length, greaterThan(out[i - 1].length));
      }
    });

    test('POST body carries the activity system prompt + flattened events',
        () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _assistantEvent('A calm recap.'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(dio: dio);

      await provider
          .generateActivitySummary(lastNHours: 24, events: events)
          .toList();

      expect(adapter.lastRequest!.uri.toString(), claudeShimEndpoint);
      final Map<String, dynamic> sent = adapter.lastRequestBody!;
      expect(sent['system'], equals(activitySummarySystemPrompt));
      final String user = sent['user'] as String;
      expect(user, contains('window_hours: 24'));
      expect(user, contains('[journal] Mom got upset before dinner'));
      expect(user, contains('[dose] Gave Donepezil 10 mg'));
      // Oldest first — the journal note precedes the later dose.
      expect(user.indexOf('Mom got upset'), lessThan(user.indexOf('Donepezil')));
    });

    test('buildActivityUserMessage tags part-of-day, oldest first', () {
      final String msg = ClaudeCLIProvider.buildActivityUserMessage(
        lastNHours: 24,
        events: <ActivityEvent>[
          ActivityEvent(
            kind: ActivityEventKind.journal,
            summary: 'Morning walk',
            occurredAt: DateTime.utc(2026, 6, 1, 9),
          ),
          ActivityEvent(
            kind: ActivityEventKind.appointment,
            summary: 'Appointment with Dr. Reyes',
            occurredAt: DateTime.utc(2026, 6, 1, 22),
          ),
        ],
      );
      expect(msg, startsWith('window_hours: 24\n'));
      expect(msg, contains('morning · [journal] Morning walk'));
      expect(msg,
          contains('night · [appointment] Appointment with Dr. Reyes'));
    });

    test('a shim error event surfaces as a stream error', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        'data: ${json.encode(<String, String>{'error': 'claude binary not found on PATH'})}\n\n',
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(dio: dio);
      await expectLater(
        provider.generateActivitySummary(events: events).toList(),
        throwsA(isA<Exception>()),
      );
    });

    test('transport failure surfaces as a stream error', () async {
      final _ThrowingAdapter adapter = _ThrowingAdapter();
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(dio: dio);
      await expectLater(
        provider.generateActivitySummary(events: events).toList(),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('ActivityEvent — cache fingerprint (Phase 14.12)', () {
    test('cacheToken is content-stable and UTC-normalized', () {
      final ActivityEvent local = ActivityEvent(
        kind: ActivityEventKind.dose,
        summary: 'Gave Donepezil 10 mg',
        occurredAt: DateTime.utc(2026, 6, 1, 19).toLocal(),
      );
      final ActivityEvent utc = ActivityEvent(
        kind: ActivityEventKind.dose,
        summary: 'Gave Donepezil 10 mg',
        occurredAt: DateTime.utc(2026, 6, 1, 19),
      );
      expect(local.cacheToken, utc.cacheToken);
      expect(local.cacheToken, contains('dose'));
    });
  });

  group('llmProvider riverpod wiring', () {
    test('defaults to FakeLLMProvider under test (USE_FAKE_LLM=true)',
        () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final LLMProvider impl = container.read(llmProvider);
      expect(impl, isA<FakeLLMProvider>());
    });

    test('override hook swaps in a custom impl', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          llmProvider.overrideWithValue(
            const FakeLLMProvider(delay: Duration.zero),
          ),
        ],
      );
      addTearDown(container.dispose);
      final LLMProvider impl = container.read(llmProvider);
      final List<String> out = await impl
          .generateActivitySummary(events: <ActivityEvent>[
        ActivityEvent(
          kind: ActivityEventKind.journal,
          summary: 'A note',
          occurredAt: DateTime.utc(2026, 6, 1, 12),
        ),
      ]).toList();
      expect(out.last, fakeActivitySummary);
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Build one SSE `data: ...\n\n` frame for a Claude-Code-style
/// `assistant` event with [text] as the sole text content block.
String _assistantEvent(String text) {
  final Map<String, dynamic> event = <String, dynamic>{
    'type': 'assistant',
    'message': <String, dynamic>{
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': text},
      ],
    },
  };
  return 'data: ${json.encode(event)}\n\n';
}

/// HTTP adapter that returns a canned SSE byte stream and records the
/// request body for assertion. Splits the stream across multiple
/// `Uint8List`s so the provider's `\n\n`-boundary parser exercises the
/// "event split across chunks" code path.
class _CannedSseAdapter implements HttpClientAdapter {
  _CannedSseAdapter(this._events);

  final List<String> _events;
  RequestOptions? lastRequest;
  Map<String, dynamic>? lastRequestBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (options.data is Map) {
      lastRequestBody = Map<String, dynamic>.from(options.data as Map);
    } else if (requestStream != null) {
      final List<int> bytes = <int>[];
      await for (final Uint8List part in requestStream) {
        bytes.addAll(part);
      }
      lastRequestBody = json.decode(utf8.decode(bytes))
          as Map<String, dynamic>;
    }

    final Stream<Uint8List> bodyStream = _emit(_events);
    return ResponseBody(
      bodyStream,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/event-stream'],
      },
    );
  }

  Stream<Uint8List> _emit(List<String> events) async* {
    for (final String e in events) {
      // Split each event in half to force the provider to glue two
      // partial reads into a complete `\n\n`-terminated event.
      final List<int> bytes = utf8.encode(e);
      if (bytes.length < 4) {
        yield Uint8List.fromList(bytes);
        continue;
      }
      final int mid = bytes.length ~/ 2;
      yield Uint8List.fromList(bytes.sublist(0, mid));
      yield Uint8List.fromList(bytes.sublist(mid));
    }
  }

  @override
  void close({bool force = false}) {}
}

/// HTTP adapter that throws on every request — exercises the
/// transport-failure branch.
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return Future<ResponseBody>.error(
      DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'connection refused',
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}

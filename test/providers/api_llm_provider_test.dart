import 'dart:convert';
import 'dart:typed_data';

import 'package:holdclose/providers/llm_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const String _base = 'https://api.holdclose.test';

final List<ActivityEvent> _events = <ActivityEvent>[
  ActivityEvent(
    kind: ActivityEventKind.journal,
    summary: 'Mom ate a full lunch',
    occurredAt: DateTime(2026, 1, 1, 9),
  ),
];

String _text(String t) => 'data: ${json.encode(<String, String>{'text': t})}\n\n';

ApiLLMProvider _provider(Dio dio, {Future<String> Function()? tokenLoader}) =>
    ApiLLMProvider(
      baseUrl: _base,
      tokenLoader: tokenLoader ?? (() async => 'test-token'),
      dio: dio,
    );

void main() {
  group('ApiLLMProvider.generateActivitySummary', () {
    test('POSTs to /api/v1/chat tagged feature:recap with the bearer token',
        () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _text('All calm today.'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      await _provider(dio).generateActivitySummary(events: _events).toList();

      expect(adapter.lastRequest!.path, '$_base/api/v1/chat');
      expect(adapter.lastRequest!.headers['Authorization'], 'Bearer test-token');
      expect(adapter.lastRequestBody!['feature'], 'recap');
      expect(adapter.lastRequestBody!['system'], isNotEmpty);
      expect(adapter.lastRequestBody!['user'], contains('Mom ate a full lunch'));
    });

    test('accumulates text deltas into the growing paragraph', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _text('A quiet '),
        _text('morning.'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final List<String> chunks =
          await _provider(dio).generateActivitySummary(events: _events).toList();

      expect(chunks, <String>['A quiet ', 'A quiet morning.']);
    });

    test('empty events short-circuit with no request', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final List<String> out = await _provider(dio)
          .generateActivitySummary(events: const <ActivityEvent>[])
          .toList();

      expect(out, <String>['']);
      expect(adapter.lastRequest, isNull);
    });

    test('an error event throws', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        'data: ${json.encode(<String, String>{'error': 'coach_unavailable'})}\n\n',
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      await expectLater(
        _provider(dio).generateActivitySummary(events: _events).toList(),
        throwsA(isA<Exception>()),
      );
    });

    test('a 429 quota response throws (no parse)', () async {
      final _CannedSseAdapter adapter =
          _CannedSseAdapter(<String>['{"error":"daily_limit"}'], status: 429);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      await expectLater(
        _provider(dio).generateActivitySummary(events: _events).toList(),
        throwsA(isA<Exception>()),
      );
    });

    test('a failing token loader throws before any request', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      await expectLater(
        _provider(dio, tokenLoader: () async => throw StateError('no session'))
            .generateActivitySummary(events: _events)
            .toList(),
        throwsA(isA<Exception>()),
      );
      expect(adapter.lastRequest, isNull);
    });
  });
}

class _CannedSseAdapter implements HttpClientAdapter {
  _CannedSseAdapter(this._events, {this.status = 200});

  final List<String> _events;
  final int status;
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
    }
    return ResponseBody(
      _emit(_events),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/event-stream'],
      },
    );
  }

  Stream<Uint8List> _emit(List<String> events) async* {
    for (final String e in events) {
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

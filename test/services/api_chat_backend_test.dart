import 'dart:convert';
import 'dart:typed_data';

import 'package:holdclose/models/chat.dart';
import 'package:holdclose/services/api_chat_backend.dart';
import 'package:holdclose/services/chat_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const String _base = 'https://api.holdclose.test';
const List<ChatTurn> _hello = <ChatTurn>[
  ChatTurn(role: MessageRole.user, content: 'hello there'),
];

String _text(String t) => 'data: ${json.encode(<String, String>{'text': t})}\n\n';

ApiChatBackend _backend(Dio dio, {ChatTokenLoader? tokenLoader}) =>
    ApiChatBackend(
      baseUrl: _base,
      tokenLoader: tokenLoader ?? (() async => 'test-token'),
      dio: dio,
    );

void main() {
  group('ApiChatBackend.streamReply', () {
    test('POSTs {system, user} to /api/v1/chat with the bearer token', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _text('Hi back.'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      await _backend(dio)
          .streamReply(systemPrompt: 'SYS', history: _hello)
          .toList();

      expect(adapter.lastRequest!.path, '$_base/api/v1/chat');
      expect(
        adapter.lastRequest!.headers['Authorization'],
        'Bearer test-token',
      );
      expect(adapter.lastRequestBody!['system'], 'SYS');
      expect(adapter.lastRequestBody!['user'], contains('hello there'));
    });

    test('yields one ChatDeltaText per text event, ending at [DONE]', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _text('First. '),
        _text('Second.'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final List<ChatDelta> deltas = await _backend(dio)
          .streamReply(systemPrompt: 'SYS', history: _hello)
          .toList();

      final List<String> texts = deltas
          .whereType<ChatDeltaText>()
          .map((ChatDeltaText d) => d.text)
          .toList();
      expect(texts, <String>['First. ', 'Second.']);
      expect(deltas.whereType<ChatDeltaError>(), isEmpty);
    });

    test('decodes a multi-byte glyph split across two reads', () async {
      // The adapter splits each event in half; an em-dash (3 UTF-8 bytes)
      // must survive a mid-character boundary.
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _text('a—b'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final List<ChatDelta> deltas = await _backend(dio)
          .streamReply(systemPrompt: 'SYS', history: _hello)
          .toList();
      final String joined = deltas
          .whereType<ChatDeltaText>()
          .map((ChatDeltaText d) => d.text)
          .join();
      expect(joined, 'a—b');
    });

    test('surfaces a mid-stream error event as ChatDeltaError', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _text('partial '),
        'data: ${json.encode(<String, String>{'error': 'coach_unavailable'})}\n\n',
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final List<ChatDelta> deltas = await _backend(dio)
          .streamReply(systemPrompt: 'SYS', history: _hello)
          .toList();
      expect(deltas.last, isA<ChatDeltaError>());
      expect((deltas.last as ChatDeltaError).message, 'coach_unavailable');
    });

    test('maps a 429 quota response to a ChatDeltaError (no parse)', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(
        <String>['{"error":"daily_limit"}'],
        status: 429,
      );
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final List<ChatDelta> deltas = await _backend(dio)
          .streamReply(systemPrompt: 'SYS', history: _hello)
          .toList();
      expect(deltas, hasLength(1));
      expect(deltas.single, isA<ChatDeltaError>());
      expect((deltas.single as ChatDeltaError).message, contains('429'));
    });

    test('maps a 503 capacity response to a ChatDeltaError', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(
        <String>['{"error":"capacity"}'],
        status: 503,
      );
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final List<ChatDelta> deltas = await _backend(dio)
          .streamReply(systemPrompt: 'SYS', history: _hello)
          .toList();
      expect((deltas.single as ChatDeltaError).message, contains('503'));
    });

    test('a transport failure yields a ChatDeltaError, not a throw', () async {
      final Dio dio = Dio()..httpClientAdapter = _ThrowingAdapter();

      final List<ChatDelta> deltas = await _backend(dio)
          .streamReply(systemPrompt: 'SYS', history: _hello)
          .toList();
      expect(deltas.single, isA<ChatDeltaError>());
    });

    test('a failing token loader yields a ChatDeltaError (no request)',
        () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[]);
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final List<ChatDelta> deltas = await _backend(
        dio,
        tokenLoader: () async => throw StateError('no session'),
      ).streamReply(systemPrompt: 'SYS', history: _hello).toList();

      expect(deltas.single, isA<ChatDeltaError>());
      expect(adapter.lastRequest, isNull);
    });
  });
}

/// Returns canned SSE events as a split byte stream (mirrors the shim
/// backend's test adapter) and captures the request for assertions.
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

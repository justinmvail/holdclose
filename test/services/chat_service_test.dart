import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/providers/llm_provider.dart' show claudeShimEndpoint;
import 'package:careblazers/seed/chat_system_prompt.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/chat_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedClock() => DateTime.utc(2026, 5, 29, 19, 42);

/// Scripted chat backend — yields the canned [deltas] in order and
/// closes. Captures the [systemPrompt] + [history] from each call so
/// tests can assert on what ChatService passed through.
class _ScriptedChatBackend implements ChatLLMBackend {
  _ScriptedChatBackend(this.deltas);

  final List<ChatDelta> deltas;
  String? lastSystemPrompt;
  List<ChatTurn>? lastHistory;
  int callCount = 0;

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    callCount++;
    lastSystemPrompt = systemPrompt;
    lastHistory = history;
    for (final ChatDelta d in deltas) {
      yield d;
    }
  }
}

/// Mints monotonically increasing ids so each call gets a fresh value
/// — ChatService consumes two ids per `sendMessage` (one for the user
/// turn, one for the assistant placeholder).
String Function() _idFactory() {
  int n = 0;
  return () => 'msg-${++n}';
}

void main() {
  group('ChatService.sendMessage — TASKS.md Phase 11.3', () {
    late CareblazersDatabase db;
    late ChatRepository repo;

    setUp(() async {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = ChatRepository(db);
      await repo.createConversation(
        id: 'convo-1',
        title: 'sundowning chat',
        createdAt: _fixedClock(),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('appends the user message to the repository first', () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('Hello, Careblazer.'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final List<Message> emitted = await svc
          .sendMessage(
            conversationId: 'convo-1',
            userText: 'What is sundowning?',
          )
          .toList();

      expect(emitted.first.role, MessageRole.user);
      expect(emitted.first.body, 'What is sundowning?');
      expect(emitted.first.streamingDone, isTrue);
      // The user turn lands in the repo before the LLM is invoked so
      // the chat screen can render it immediately.
      final List<Message> persisted = await repo.loadMessages('convo-1');
      expect(persisted.first.role, MessageRole.user);
      expect(persisted.first.body, 'What is sundowning?');
    });

    test('forwards chatSystemPrompt + history to the backend', () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('ok'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      await svc
          .sendMessage(
            conversationId: 'convo-1',
            userText: 'tell me about anosognosia',
          )
          .toList();

      expect(backend.lastSystemPrompt, equals(chatSystemPrompt));
      expect(backend.lastHistory, hasLength(1));
      expect(backend.lastHistory!.single.role, MessageRole.user);
      expect(backend.lastHistory!.single.content,
          'tell me about anosognosia');
    });

    test(
      'sends prior turns plus the just-appended user message as history',
      () async {
        // Seed two prior turns on this thread.
        await repo.appendMessage(Message(
          id: 'prior-u',
          conversationId: 'convo-1',
          role: MessageRole.user,
          body: 'hi',
          citations: const <String>[],
          createdAt: _fixedClock().subtract(const Duration(minutes: 2)),
          streamingDone: true,
        ));
        await repo.appendMessage(Message(
          id: 'prior-a',
          conversationId: 'convo-1',
          role: MessageRole.assistant,
          body: 'hello, Careblazer',
          citations: const <String>[],
          createdAt: _fixedClock().subtract(const Duration(minutes: 1)),
          streamingDone: true,
        ));

        final _ScriptedChatBackend backend = _ScriptedChatBackend(
            <ChatDelta>[const ChatDeltaText('sure thing')]);
        final ChatService svc = ChatService(
          repository: repo,
          backend: backend,
          idFactory: _idFactory(),
          clock: _fixedClock,
        );

        await svc
            .sendMessage(
              conversationId: 'convo-1',
              userText: 'tell me more',
            )
            .toList();

        final List<ChatTurn> history = backend.lastHistory!;
        expect(history.map((ChatTurn t) => t.role).toList(),
            <MessageRole>[
              MessageRole.user,
              MessageRole.assistant,
              MessageRole.user,
            ]);
        expect(history.map((ChatTurn t) => t.content).toList(),
            <String>['hi', 'hello, Careblazer', 'tell me more']);
      },
    );

    test('builds the assistant body incrementally across deltas', () async {
      final _ScriptedChatBackend backend =
          _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('Sundowning '),
        const ChatDeltaText('is the late-afternoon '),
        const ChatDeltaText('shift many Careblazers notice.'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final List<Message> emitted = await svc
          .sendMessage(
            conversationId: 'convo-1',
            userText: 'what is sundowning?',
          )
          .toList();

      // user + assistant-placeholder + 3 deltas + final done = 6
      expect(emitted, hasLength(6));
      // Skip the user turn at index 0.
      final List<Message> assistantSnapshots = emitted.skip(1).toList();
      // All assistant snapshots share the same id (the placeholder gets
      // overwritten in place by `insertOnConflictUpdate`).
      expect(assistantSnapshots.map((Message m) => m.id).toSet().length, 1);
      // Body grows by one fragment per delta.
      expect(assistantSnapshots.map((Message m) => m.body).toList(),
          <String>[
            '',
            'Sundowning ',
            'Sundowning is the late-afternoon ',
            'Sundowning is the late-afternoon shift many Careblazers notice.',
            'Sundowning is the late-afternoon shift many Careblazers notice.',
          ]);
      // The final snapshot is the only one with streamingDone=true.
      expect(
          assistantSnapshots
              .where((Message m) => m.streamingDone)
              .toList()
              .length,
          1);
      expect(assistantSnapshots.last.streamingDone, isTrue);
    });

    test('the final assistant row in the repo carries the complete body',
        () async {
      final _ScriptedChatBackend backend =
          _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('A: '),
        const ChatDeltaText('B '),
        const ChatDeltaText('C.'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      await svc
          .sendMessage(conversationId: 'convo-1', userText: 'ping')
          .toList();

      final List<Message> stored = await repo.loadMessages('convo-1');
      expect(stored, hasLength(2));
      expect(stored[1].role, MessageRole.assistant);
      expect(stored[1].body, 'A: B C.');
      expect(stored[1].streamingDone, isTrue);
    });

    // ---- Citation parsing (task acceptance: 0, 1, and many) -------------

    test('citation parsing: zero markers → empty citations list', () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('No card references at all.'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final List<Message> emitted = await svc
          .sendMessage(conversationId: 'convo-1', userText: 'hello')
          .toList();
      expect(emitted.last.citations, isEmpty);
    });

    test('journal-action: marker stripped + executor invoked', () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText(
            "Logged that one for you.\n"
            '[action:log_journal occurred_at="just now" '
            'situation="Mom asked for her mother" '
            'attempts="I told her she went to the store"]'),
      ]);
      JournalEntry? captured;
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
        journalExecutor: ({
          required DateTime occurredAt,
          required String situation,
          required String attempts,
        }) async {
          captured = JournalEntry.wizard(
            id: 'test-entry-1',
            createdAt: occurredAt,
            occurredAt: occurredAt,
            situationText: situation,
            attemptsText: attempts,
          );
          return captured;
        },
      );

      final List<Message> emitted = await svc
          .sendMessage(conversationId: 'convo-1', userText: 'log it')
          .toList();
      expect(emitted.last.body, 'Logged that one for you.');
      expect(emitted.last.citations, <String>['journal:test-entry-1']);
      expect(captured, isNotNull);
      expect(captured!.situationText, 'Mom asked for her mother');
      expect(captured!.attemptsText, 'I told her she went to the store');
    });

    test('journal-action: no executor wired → marker stripped, no citation',
        () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText(
            'Acknowledged.\n[action:log_journal situation="x" attempts="y"]'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
        // No journalExecutor — marker is stripped but no entry written.
      );

      final List<Message> emitted = await svc
          .sendMessage(conversationId: 'convo-1', userText: 'nothing')
          .toList();
      expect(emitted.last.body, 'Acknowledged.');
      expect(emitted.last.citations, isEmpty);
    });

    test('plain prose with no action tag passes through unchanged',
        () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText("That sounds like a hard moment."),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
      );
      await svc
          .sendMessage(conversationId: 'convo-1', userText: 'x')
          .toList();

      final List<Message> stored = await repo.loadMessages('convo-1');
      expect(stored.last.body, 'That sounds like a hard moment.');
      expect(stored.last.citations, isEmpty);
    });

    // ---- Error path ------------------------------------------------------

    test('error delta closes the assistant message with streamingDone=true',
        () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('partial body so far '),
        const ChatDeltaError('shim went offline'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final List<Message> emitted = await svc
          .sendMessage(conversationId: 'convo-1', userText: 'bad')
          .toList();
      final Message finalMsg = emitted.last;
      expect(finalMsg.role, MessageRole.assistant);
      expect(finalMsg.streamingDone, isTrue);
      expect(finalMsg.body, contains('partial body so far'));
      expect(finalMsg.body, contains('shim went offline'));

      // And the same finalized state lands in the repo so the chat
      // screen sees the failed reply on reload.
      final List<Message> stored = await repo.loadMessages('convo-1');
      expect(stored.last.body, contains('shim went offline'));
      expect(stored.last.streamingDone, isTrue);
    });

    test('error before any text still finalises the assistant message',
        () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaError('connection refused'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final List<Message> emitted = await svc
          .sendMessage(conversationId: 'convo-1', userText: 'oops')
          .toList();
      final Message finalMsg = emitted.last;
      expect(finalMsg.streamingDone, isTrue);
      expect(finalMsg.body, contains('connection refused'));
    });

    // ---- Static helpers --------------------------------------------------

    test('ChatService.stripActionMarkers: passes through plain prose', () {
      expect(ChatService.stripActionMarkers('plain reply'), 'plain reply');
    });

    test('ChatService.stripActionMarkers: strips an action tag at the end',
        () {
      final String stripped = ChatService.stripActionMarkers(
        'I logged that moment for you.\n'
        '[action:log_journal occurred_at="just now" situation="X" attempts="Y"]',
      );
      expect(stripped, 'I logged that moment for you.');
    });

    test('ChatService.stripActionMarkers: tolerates a stray marker mid-text',
        () {
      final String stripped = ChatService.stripActionMarkers(
        'Before [action:log_journal situation="hi" attempts="ok"] after.',
      );
      expect(stripped, 'Before  after.');
    });
  });

  // ---- Backend wiring ---------------------------------------------------

  group('chatServiceProvider', () {
    test('resolves to a ChatService wired with the riverpod backends',
        () async {
      final CareblazersDatabase db =
          CareblazersDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final ChatRepository repo = ChatRepository(db);
      await repo.createConversation(
        id: 'wire',
        title: 'wired',
        createdAt: _fixedClock(),
      );

      final _ScriptedChatBackend backend = _ScriptedChatBackend(
          <ChatDelta>[const ChatDeltaText('hello back')]);
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          chatLLMBackendProvider.overrideWithValue(backend),
          chatRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(c.dispose);

      final ChatService svc = c.read(chatServiceProvider);
      expect(svc.repository, same(repo));
      expect(svc.backend, same(backend));

      await svc
          .sendMessage(conversationId: 'wire', userText: 'hello')
          .toList();
      final List<Message> stored = await repo.loadMessages('wire');
      expect(stored, hasLength(2));
      expect(stored.last.body, 'hello back');
    });
  });

  // ---- ClaudeShimChatBackend ------------------------------------------

  group('ClaudeShimChatBackend.formatHistory', () {
    test('returns empty string for empty history', () {
      expect(ClaudeShimChatBackend.formatHistory(const <ChatTurn>[]), '');
    });

    test('a single user turn renders without the conversation header', () {
      final String formatted = ClaudeShimChatBackend.formatHistory(
        const <ChatTurn>[
          ChatTurn(role: MessageRole.user, content: 'what is sundowning?'),
        ],
      );
      expect(formatted, isNot(contains('[Conversation so far]')));
      expect(formatted, contains('[Latest Careblazer message]'));
      expect(formatted, contains('what is sundowning?'));
    });

    test('multi-turn history is rendered with role labels + a latest line',
        () {
      final String formatted = ClaudeShimChatBackend.formatHistory(
        const <ChatTurn>[
          ChatTurn(role: MessageRole.user, content: 'q1'),
          ChatTurn(role: MessageRole.assistant, content: 'a1'),
          ChatTurn(role: MessageRole.user, content: 'q2'),
        ],
      );
      expect(formatted, contains('[Conversation so far]'));
      expect(formatted, contains('Careblazer: q1'));
      expect(formatted, contains('Coach: a1'));
      expect(formatted, contains('[Latest Careblazer message]'));
      expect(formatted, contains('q2'));
      // The latest message is NOT in the "so far" block.
      expect(formatted.indexOf('q2'),
          greaterThan(formatted.indexOf('[Latest Careblazer message]')));
    });
  });

  group('ClaudeShimChatBackend.streamReply', () {
    test('POSTs {system, user} to the shim endpoint with the formatted '
        'history', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _assistantEvent('Hi back.'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeShimChatBackend backend = ClaudeShimChatBackend(dio: dio);

      await backend
          .streamReply(
            systemPrompt: 'SYS',
            history: const <ChatTurn>[
              ChatTurn(role: MessageRole.user, content: 'hello there'),
            ],
          )
          .toList();

      expect(adapter.lastRequest!.path, claudeShimEndpoint);
      expect(adapter.lastRequestBody!['system'], 'SYS');
      expect(adapter.lastRequestBody!['user'],
          contains('hello there'));
    });

    test('yields one ChatDeltaText per non-empty assistant event', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _assistantEvent('First fragment. '),
        _assistantEvent('Second fragment.'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeShimChatBackend backend = ClaudeShimChatBackend(dio: dio);

      final List<ChatDelta> deltas = await backend
          .streamReply(
            systemPrompt: 'SYS',
            history: const <ChatTurn>[
              ChatTurn(role: MessageRole.user, content: 'q'),
            ],
          )
          .toList();

      final List<ChatDeltaText> texts =
          deltas.whereType<ChatDeltaText>().toList();
      expect(texts.map((ChatDeltaText t) => t.text).toList(),
          <String>['First fragment. ', 'Second fragment.']);
      // No error events.
      expect(deltas.whereType<ChatDeltaError>(), isEmpty);
    });

    test('surfaces an {error: ...} event as a single ChatDeltaError',
        () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        'data: {"error": "shim crashed"}\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeShimChatBackend backend = ClaudeShimChatBackend(dio: dio);

      final List<ChatDelta> deltas = await backend
          .streamReply(
            systemPrompt: 'SYS',
            history: const <ChatTurn>[
              ChatTurn(role: MessageRole.user, content: 'q'),
            ],
          )
          .toList();
      expect(deltas, hasLength(1));
      expect(deltas.single, isA<ChatDeltaError>());
      expect((deltas.single as ChatDeltaError).message, 'shim crashed');
    });

    test('a transport failure yields ChatDeltaError', () async {
      final Dio dio = Dio()..httpClientAdapter = _ThrowingAdapter();
      final ClaudeShimChatBackend backend = ClaudeShimChatBackend(dio: dio);

      final List<ChatDelta> deltas = await backend
          .streamReply(
            systemPrompt: 'SYS',
            history: const <ChatTurn>[
              ChatTurn(role: MessageRole.user, content: 'q'),
            ],
          )
          .toList();
      expect(deltas, hasLength(1));
      expect(deltas.single, isA<ChatDeltaError>());
      expect((deltas.single as ChatDeltaError).message,
          contains('shim request failed'));
    });
  });
}

/// Format an assistant-text SSE event the way the shim forwards them —
/// `data: {"type":"assistant","message":{"content":[{"type":"text",...}]}}`
/// followed by the SSE blank-line terminator.
String _assistantEvent(String text) {
  final Map<String, Object?> event = <String, Object?>{
    'type': 'assistant',
    'message': <String, Object?>{
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': text},
      ],
    },
  };
  return 'data: ${json.encode(event)}\n\n';
}

/// Adapter that returns a canned SSE byte stream and records the
/// request body. Splits each event across two reads so the backend's
/// `\n\n`-boundary parser exercises the "event split across chunks"
/// code path.
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
      lastRequestBody =
          json.decode(utf8.decode(bytes)) as Map<String, dynamic>;
    }
    return ResponseBody(
      _emit(_events),
      200,
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

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/providers/care_plan_provider.dart'
    show carePlanRepositoryProvider, CarePlanRepository;
import 'package:careblazers/providers/health_log_provider.dart'
    show healthLogRepositoryProvider, HealthLogRepository;
import 'package:careblazers/providers/llm_provider.dart' show claudeShimEndpoint;
import 'package:careblazers/providers/storage_provider.dart'
    show storageProvider, InMemoryStorageProvider;
import 'package:careblazers/seed/chat_system_prompt.dart';
import 'package:careblazers/services/appointment_repository.dart'
    show appointmentRepositoryProvider, AppointmentRepository;
import 'package:careblazers/services/chat_actions.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/chat_service.dart';
import 'package:careblazers/services/medication_repository.dart'
    show medicationRepositoryProvider, MedicationRepository;
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

/// A repo whose [loadMessages] throws — proves a mid-turn failure (before
/// the LLM is even reached) surfaces as a visible error bubble instead of
/// an empty stream the screen swallows ("nothing happens after I hit send").
class _LoadThrowsRepo extends ChatRepository {
  _LoadThrowsRepo(super.db);

  @override
  Future<List<Message>> loadMessages(String conversationId) async {
    throw StateError('boom');
  }
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

    test('a mid-turn repo failure surfaces a visible error, not a dead stream',
        () async {
      // Regression for the alpha "nothing happens after I hit send": the
      // user message must still appear AND a failure after it (here a
      // throwing loadMessages) must emit a visible, error-flagged assistant
      // bubble — never an empty/erroring stream the screen swallows.
      final _LoadThrowsRepo throwingRepo = _LoadThrowsRepo(db);
      final ChatService svc = ChatService(
        repository: throwingRepo,
        backend: _ScriptedChatBackend(<ChatDelta>[const ChatDeltaText('hi')]),
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final List<Message> emitted = await svc
          .sendMessage(conversationId: 'convo-1', userText: 'ping')
          .toList();

      expect(emitted.first.role, MessageRole.user); // message still shows
      expect(emitted.last.role, MessageRole.assistant);
      expect(emitted.last.streamingDone, isTrue);
      expect(chatBodyHasError(emitted.last.body), isTrue); // visible error
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

    test('appends the fresh data snapshot under the system prompt', () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('ok'),
      ]);
      int calls = 0;
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
        // A fresh snapshot per turn — the counter proves it's re-fetched.
        contextSnapshot: () async {
          calls++;
          return 'CURRENT DATA (read-only):\nLoved one: Mary, 78.';
        },
      );

      await svc
          .sendMessage(conversationId: 'convo-1', userText: 'what meds?')
          .toList();

      expect(calls, 1);
      expect(backend.lastSystemPrompt, startsWith(chatSystemPrompt));
      expect(backend.lastSystemPrompt, contains('Loved one: Mary, 78.'));
    });

    test('a snapshot failure still streams the reply (prompt unchanged)',
        () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('ok'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
        contextSnapshot: () async => throw StateError('snapshot boom'),
      );

      final List<Message> emitted = await svc
          .sendMessage(conversationId: 'convo-1', userText: 'hi')
          .toList();

      // The turn completed normally and the prompt fell back to the base.
      expect(backend.lastSystemPrompt, equals(chatSystemPrompt));
      expect(emitted.last.body, 'ok');
      expect(emitted.last.streamingDone, isTrue);
    });

    test('an empty snapshot leaves the prompt exactly equal to the base',
        () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('ok'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
        contextSnapshot: () async => '   ',
      );

      await svc
          .sendMessage(conversationId: 'convo-1', userText: 'hi')
          .toList();

      expect(backend.lastSystemPrompt, equals(chatSystemPrompt));
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
      Map<String, String>? captured;
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
        actions: <String, ChatActionExecutor>{
          'log_journal': (Map<String, String> args) async {
            captured = args;
            return const ChatActionOutcome(citation: 'journal:test-entry-1');
          },
        },
      );

      final List<Message> emitted = await svc
          .sendMessage(conversationId: 'convo-1', userText: 'log it')
          .toList();
      expect(emitted.last.body, 'Logged that one for you.');
      expect(emitted.last.citations, <String>['journal:test-entry-1']);
      // The registry hands the executor the parsed key="value" args.
      expect(captured, isNotNull);
      expect(captured!['situation'], 'Mom asked for her mother');
      expect(captured!['attempts'], 'I told her she went to the store');
      expect(captured!['occurred_at'], 'just now');
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
        // No actions registered — marker is stripped but nothing written.
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
      // The failed-turn sentinel is present so the chat screen can detect it
      // and surface the inline retry (#19).
      expect(finalMsg.body, contains(chatErrorMarkerPrefix));
      expect(chatBodyHasError(finalMsg.body), isTrue);

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

    test('chatBodyHasError: detects the failed-turn sentinel (#19)', () {
      expect(chatBodyHasError('a normal reply'), isFalse);
      expect(chatBodyHasError(''), isFalse);
      expect(
        chatBodyHasError('partial\n\n[chat error: shim offline]'),
        isTrue,
      );
      expect(chatBodyHasError('[chat error: connection refused]'), isTrue);
    });

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

    // ---- displayBody: the render-time sanitiser (alpha bug) -------------

    test('ChatService.displayBody: plain prose passes through unchanged', () {
      expect(
        ChatService.displayBody('Step into her reality and validate.'),
        'Step into her reality and validate.',
      );
    });

    test('ChatService.displayBody: strips an [action:…] navigate marker', () {
      final String shown = ChatService.displayBody(
        'I pulled up the calendar for you.\n'
        '[action:navigate target="calendar" date="2026-07-01"]',
      );
      expect(shown, 'I pulled up the calendar for you.');
      // The raw marker text must not survive into the displayed string.
      expect(shown, isNot(contains('[action:')));
      expect(shown, isNot(contains('navigate')));
      expect(shown, isNot(contains('target=')));
    });

    test('ChatService.displayBody: swaps a raw [chat error: …] trailer for '
        'the friendly line and drops the DioException detail', () {
      const String raw =
          '[chat error: shim request failed: DioException [connection error]: '
          'The connection errored: Connection refused]';
      final String shown = ChatService.displayBody(raw);

      expect(shown, chatFriendlyErrorMessage);
      // None of the internal/transport vocabulary leaks to the caregiver.
      expect(shown, isNot(contains('chat error')));
      expect(shown, isNot(contains('DioException')));
      expect(shown, isNot(contains('shim')));
      expect(shown, isNot(contains('connection error')));
    });

    test('ChatService.displayBody: keeps a partial reply and appends the '
        'friendly line when the stream failed mid-answer', () {
      const String raw =
          'Pacing often means restless energy.\n\n'
          '[chat error: shim request failed: DioException [connection error]]';
      final String shown = ChatService.displayBody(raw);

      expect(shown, contains('Pacing often means restless energy.'));
      expect(shown, endsWith(chatFriendlyErrorMessage));
      expect(shown, isNot(contains('DioException')));
      expect(shown, isNot(contains('chat error')));
    });

    test('ChatService.displayBody: friendly message itself names no '
        'AI/model/shim/transport detail', () {
      // Guards the brand-voice rule — the LLM stays invisible.
      for (final String banned in const <String>[
        'AI',
        'model',
        'shim',
        'JSON',
        'DioException',
        'LLM',
      ]) {
        expect(chatFriendlyErrorMessage, isNot(contains(banned)));
      }
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
      // The wired chatServiceProvider now reads the caregiver's current
      // data each turn (for the read-only snapshot); override those data
      // providers with in-memory backends so the read is harmless here
      // (no real shared DB / platform channels in a binding-less test).
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final MedicationRepository medRepo = MedicationRepository(db);
      final AppointmentRepository apptRepo = AppointmentRepository(db);
      final CarePlanRepository carePlanRepo = CarePlanRepository(db);
      final HealthLogRepository healthRepo = HealthLogRepository(db);
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          chatLLMBackendProvider.overrideWithValue(backend),
          chatRepositoryProvider.overrideWithValue(repo),
          storageProvider.overrideWithValue(storage),
          medicationRepositoryProvider.overrideWithValue(medRepo),
          appointmentRepositoryProvider.overrideWithValue(apptRepo),
          carePlanRepositoryProvider.overrideWithValue(carePlanRepo),
          healthLogRepositoryProvider.overrideWithValue(healthRepo),
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

    test('requests token streaming via partial:true in the body', () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _assistantEvent('hi'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeShimChatBackend backend = ClaudeShimChatBackend(dio: dio);

      await backend
          .streamReply(
            systemPrompt: 'SYS',
            history: const <ChatTurn>[
              ChatTurn(role: MessageRole.user, content: 'q'),
            ],
          )
          .toList();

      expect(adapter.lastRequestBody!['partial'], isTrue);
    });

    test(
        'streams partial text_delta chunks incrementally AND drops the '
        'trailing full-message echo (no doubled reply)', () async {
      // With --include-partial-messages the shim sends incremental chunks,
      // then a complete `assistant` message that repeats the whole text.
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _textDeltaEvent('Step into '),
        _textDeltaEvent('her reality. '),
        _textDeltaEvent('Say: come sit with me.'),
        _assistantEvent('Step into her reality. Say: come sit with me.'),
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

      final List<String> texts = deltas
          .whereType<ChatDeltaText>()
          .map((ChatDeltaText t) => t.text)
          .toList();
      // Only the three incremental chunks — the duplicate full echo is gone.
      expect(texts, <String>['Step into ', 'her reality. ', 'Say: come sit with me.']);
      // And they fold to exactly the message once, not twice.
      expect(texts.join(), 'Step into her reality. Say: come sit with me.');
      expect(deltas.whereType<ChatDeltaError>(), isEmpty);
    });

    test('falls back to the complete assistant message when no partials stream',
        () async {
      // Non-streaming mode (e.g. partial flag off): a lone complete message
      // is still delivered as the whole reply.
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _assistantEvent('The whole reply at once.'),
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
      expect(
        deltas.whereType<ChatDeltaText>().map((ChatDeltaText t) => t.text),
        <String>['The whole reply at once.'],
      );
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

  group('ChatService.routeVoiceIntent — hands-free mic (fb_1781029699933602)',
      () {
    late CareblazersDatabase db;
    late ChatRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = ChatRepository(db);
    });
    tearDown(() async => db.close());

    test('a spoken COMMAND runs the action and returns VoiceIntentAction '
        '— no thread', () async {
      Map<String, String>? logged;
      final ChatService svc = ChatService(
        repository: repo,
        backend: _ScriptedChatBackend(<ChatDelta>[
          const ChatDeltaText(
            'Logged that she did not sleep.\n'
            '[action:log_journal occurred_at="just now" '
            'situation="did not sleep" attempts="none"]',
          ),
        ]),
        actions: <String, ChatActionExecutor>{
          'log_journal': (Map<String, String> args) async {
            logged = args;
            return null;
          },
        },
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final VoiceIntentOutcome outcome =
          await svc.routeVoiceIntent('log that she did not sleep');

      expect(outcome, isA<VoiceIntentAction>());
      expect((outcome as VoiceIntentAction).summary,
          'Logged that she did not sleep.');
      expect(logged, isNotNull);
      expect(logged!['situation'], 'did not sleep');
      // No conversation was created — it acted in place.
      expect(await repo.listConversations(), isEmpty);
    });

    test('a spoken QUESTION opens a thread with the answer already persisted',
        () async {
      final _ScriptedChatBackend backend = _ScriptedChatBackend(<ChatDelta>[
        const ChatDeltaText('Step into her reality and reassure her.'),
      ]);
      final ChatService svc = ChatService(
        repository: repo,
        backend: backend,
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final VoiceIntentOutcome outcome =
          await svc.routeVoiceIntent('why is she pacing at night');

      expect(outcome, isA<VoiceIntentChat>());
      // Voice-mode prompt was used (not the plain chat prompt).
      expect(backend.lastSystemPrompt, equals(voiceIntentSystemPrompt));
      final List<Message> msgs =
          await repo.loadMessages((outcome as VoiceIntentChat).conversationId);
      expect(msgs.first.role, MessageRole.user);
      expect(msgs.first.body, 'why is she pacing at night');
      expect(msgs.last.role, MessageRole.assistant);
      expect(msgs.last.body, 'Step into her reality and reassure her.');
    });

    test('an UNREGISTERED action tag falls back to a chat (no false "Done")',
        () async {
      // The model sometimes invents an unsupported action name; nothing
      // would be written, so it must not flash an action confirmation.
      final ChatService svc = ChatService(
        repository: repo,
        backend: _ScriptedChatBackend(<ChatDelta>[
          const ChatDeltaText(
            'Noted.\n[action:teleport_her_home when="now"]',
          ),
        ]),
        // No executors wired — the tag matches nothing.
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final VoiceIntentOutcome outcome =
          await svc.routeVoiceIntent('teleport her home');
      expect(outcome, isA<VoiceIntentChat>());
    });

    test('a backend error opens a retryable thread instead of throwing',
        () async {
      final ChatService svc = ChatService(
        repository: repo,
        backend: _ScriptedChatBackend(<ChatDelta>[
          const ChatDeltaError('shim down'),
        ]),
        idFactory: _idFactory(),
        clock: _fixedClock,
      );

      final VoiceIntentOutcome outcome =
          await svc.routeVoiceIntent('why is she pacing');
      expect(outcome, isA<VoiceIntentChat>());
      final List<Message> msgs =
          await repo.loadMessages((outcome as VoiceIntentChat).conversationId);
      expect(chatBodyHasError(msgs.last.body), isTrue);
    });
  });
}

/// Format a partial token chunk the way the shim forwards them when run
/// with --include-partial-messages — a `stream_event` carrying a
/// `content_block_delta` / `text_delta`.
String _textDeltaEvent(String text) {
  final Map<String, Object?> event = <String, Object?>{
    'type': 'stream_event',
    'event': <String, Object?>{
      'type': 'content_block_delta',
      'index': 1,
      'delta': <String, Object?>{'type': 'text_delta', 'text': text},
    },
  };
  return 'data: ${json.encode(event)}\n\n';
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

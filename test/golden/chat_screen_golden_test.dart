import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/screens/chat/chat_screen.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/chat_service.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime.utc(2026, 5, 29, 19, 42);

/// Inert backend — never streams. Pinned so the goldens don't depend
/// on the ChatService's async stream cadence; they render the static
/// frame the screen sits at after hydration.
class _InertBackend implements ChatLLMBackend {
  const _InertBackend();

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {}
}

Future<ChatRepository> _emptyRepo() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final ChatRepository repo = ChatRepository(db);
  await repo.createConversation(
    id: 'convo-empty',
    title: 'placeholder',
    createdAt: _fixedNow(),
  );
  return repo;
}

Future<ChatRepository> _finalisedRepo() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final ChatRepository repo = ChatRepository(db);
  final DateTime now = _fixedNow();
  await repo.createConversation(
    id: 'convo-finalised',
    title: 'placeholder',
    createdAt: now,
  );
  await repo.appendMessage(Message(
    id: 'fin-1',
    conversationId: 'convo-finalised',
    role: MessageRole.user,
    body: 'What do I say when she asks for her mother?',
    citations: const <String>[],
    createdAt: now.add(const Duration(seconds: 1)),
    streamingDone: true,
  ));
  await repo.appendMessage(Message(
    id: 'fin-2',
    conversationId: 'convo-finalised',
    role: MessageRole.assistant,
    body:
        "Step into her reality. You might say: \"Tell me about her — what "
        'do you remember?" Comfort the feeling, not the fact.',
    citations: const <String>[],
    createdAt: now.add(const Duration(seconds: 3)),
    streamingDone: true,
  ));
  return repo;
}

/// A thread whose latest assistant turn FAILED — the body carries the
/// `[chat error: …]` sentinel [ChatService] stamps on a stream failure, so
/// the bubble renders the inline "Try again" affordance (#19). Seeded as a
/// finalised message so the golden is a static frame (no live stream).
Future<ChatRepository> _erroredRepo() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final ChatRepository repo = ChatRepository(db);
  final DateTime now = _fixedNow();
  await repo.createConversation(
    id: 'convo-errored',
    title: 'placeholder',
    createdAt: now,
  );
  await repo.appendMessage(Message(
    id: 'err-1',
    conversationId: 'convo-errored',
    role: MessageRole.user,
    body: 'Why does she get so anxious at dusk?',
    citations: const <String>[],
    createdAt: now.add(const Duration(seconds: 1)),
    streamingDone: true,
  ));
  await repo.appendMessage(Message(
    id: 'err-2',
    conversationId: 'convo-errored',
    role: MessageRole.assistant,
    body: '$chatErrorMarkerPrefix could not reach the coach]',
    citations: const <String>[],
    createdAt: now.add(const Duration(seconds: 2)),
    streamingDone: true,
  ));
  return repo;
}

ChatService _service(ChatRepository repo) => ChatService(
      repository: repo,
      backend: const _InertBackend(),
      idFactory: () => 'msg-golden',
      clock: _fixedNow,
    );

void main() {
  group('ChatScreen golden', () {
    goldenTest(
      'empty state — just the composer',
      fileName: 'chat_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 11.4)',
            child: FutureBuilder<ChatRepository>(
              future: _emptyRepo(),
              builder: (BuildContext context,
                  AsyncSnapshot<ChatRepository> snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                final ChatRepository repo = snapshot.data!;
                return ProviderScope(
                  overrides: <Override>[
                    chatRepositoryBackendProvider.overrideWithValue(repo),
                    chatServiceProvider.overrideWithValue(_service(repo)),
                    chatLLMBackendProvider
                        .overrideWithValue(const _InertBackend()),
                  ],
                  child: SizedBox(
                    width: 420,
                    height: 900,
                    child: MaterialApp.router(
                      routerConfig: _goldenRouter('convo-empty'),
                      builder: (BuildContext context, Widget? child) {
                        return ColoredBox(
                          color: careblazersColors.background,
                          child: child ?? const SizedBox.shrink(),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'finalised exchange — user navy bubble + assistant warm-coach bubble',
      fileName: 'chat_screen_finalised',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'finalised (Phase 11.4)',
            child: FutureBuilder<ChatRepository>(
              future: _finalisedRepo(),
              builder: (BuildContext context,
                  AsyncSnapshot<ChatRepository> snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                final ChatRepository repo = snapshot.data!;
                return ProviderScope(
                  overrides: <Override>[
                    chatRepositoryBackendProvider.overrideWithValue(repo),
                    chatServiceProvider.overrideWithValue(_service(repo)),
                    chatLLMBackendProvider
                        .overrideWithValue(const _InertBackend()),
                  ],
                  child: SizedBox(
                    width: 420,
                    height: 900,
                    child: MaterialApp.router(
                      routerConfig: _goldenRouter('convo-finalised'),
                      builder: (BuildContext context, Widget? child) {
                        return ColoredBox(
                          color: careblazersColors.background,
                          child: child ?? const SizedBox.shrink(),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'failed reply — error bubble with inline Try again (#19)',
      fileName: 'chat_screen_errored',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'errored (#19)',
            child: FutureBuilder<ChatRepository>(
              future: _erroredRepo(),
              builder: (BuildContext context,
                  AsyncSnapshot<ChatRepository> snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                final ChatRepository repo = snapshot.data!;
                return ProviderScope(
                  overrides: <Override>[
                    chatRepositoryBackendProvider.overrideWithValue(repo),
                    chatServiceProvider.overrideWithValue(_service(repo)),
                    chatLLMBackendProvider
                        .overrideWithValue(const _InertBackend()),
                  ],
                  child: SizedBox(
                    width: 420,
                    height: 900,
                    child: MaterialApp.router(
                      routerConfig: _goldenRouter('convo-errored'),
                      builder: (BuildContext context, Widget? child) {
                        return ColoredBox(
                          color: careblazersColors.background,
                          child: child ?? const SizedBox.shrink(),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  });
}

GoRouter _goldenRouter(String conversationId) {
  return GoRouter(
    initialLocation: '/chat/$conversationId',
    routes: <RouteBase>[
      GoRoute(
        path: '/chat/:id',
        builder: (BuildContext context, GoRouterState state) => ChatScreen(
          conversationId: state.pathParameters['id'] ?? '',
        ),
      ),
    ],
  );
}

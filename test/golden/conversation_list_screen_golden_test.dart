import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/screens/chat/conversation_list_screen.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime.utc(2026, 5, 29, 19, 42);

ChatRepository _seedRepoEmpty() {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  return ChatRepository(db);
}

Future<ChatRepository> _seedRepoPopulated() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final ChatRepository repo = ChatRepository(db);

  final DateTime now = _fixedNow();
  await repo.createConversation(
    id: 'convo-1',
    title: 'placeholder',
    createdAt: now.subtract(const Duration(hours: 4)),
  );
  await repo.appendMessage(Message(
    id: 'm-1',
    conversationId: 'convo-1',
    role: MessageRole.user,
    body: 'What do I say when she asks for her mother who passed years ago?',
    citations: const <String>[],
    createdAt: now.subtract(const Duration(hours: 4)),
    streamingDone: true,
  ));
  await repo.appendMessage(Message(
    id: 'm-2',
    conversationId: 'convo-1',
    role: MessageRole.assistant,
    body: 'Step into her reality — comfort the feeling, not the fact.',
    citations: const <String>[],
    createdAt: now.subtract(const Duration(hours: 4, minutes: -1)),
    streamingDone: true,
  ));

  await repo.createConversation(
    id: 'convo-2',
    title: 'placeholder',
    createdAt: now.subtract(const Duration(hours: 1)),
  );
  await repo.appendMessage(Message(
    id: 'm-3',
    conversationId: 'convo-2',
    role: MessageRole.user,
    body: 'Sundowning is hitting hard this week. What can I do?',
    citations: const <String>[],
    createdAt: now.subtract(const Duration(hours: 1)),
    streamingDone: true,
  ));

  return repo;
}

void main() {
  group('ConversationListScreen golden', () {
    goldenTest(
      'empty state — Quick Chat CTA inline',
      fileName: 'conversation_list_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 11.4)',
            child: ProviderScope(
              overrides: <Override>[
                chatRepositoryBackendProvider.overrideWithValue(_seedRepoEmpty()),
                conversationListClockProvider.overrideWithValue(_fixedNow),
                conversationListIdFactoryProvider.overrideWithValue(
                  () => 'convo-new',
                ),
              ],
              child: SizedBox(
                width: 420,
                height: 900,
                child: MaterialApp.router(
                  routerConfig: _goldenRouter(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'populated state — two conversations + FAB',
      fileName: 'conversation_list_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 11.4)',
            child: FutureBuilder<ChatRepository>(
              future: _seedRepoPopulated(),
              builder: (BuildContext context,
                  AsyncSnapshot<ChatRepository> snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                return ProviderScope(
                  overrides: <Override>[
                    chatRepositoryBackendProvider
                        .overrideWithValue(snapshot.data!),
                    conversationListClockProvider.overrideWithValue(_fixedNow),
                    conversationListIdFactoryProvider.overrideWithValue(
                      () => 'convo-new',
                    ),
                  ],
                  child: SizedBox(
                    width: 420,
                    height: 900,
                    child: MaterialApp.router(
                      routerConfig: _goldenRouter(),
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

GoRouter _goldenRouter() {
  return GoRouter(
    initialLocation: '/chat',
    routes: <RouteBase>[
      GoRoute(
        path: '/chat',
        builder: (BuildContext context, GoRouterState state) =>
            const ConversationListScreen(),
      ),
      GoRoute(
        path: '/chat/:id',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
}

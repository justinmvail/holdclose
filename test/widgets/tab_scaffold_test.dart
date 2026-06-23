import 'dart:async';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/providers/home_conversation_provider.dart';
import 'package:holdclose/providers/voice_capture_provider.dart';
import 'package:holdclose/routing/router.dart';
import 'package:holdclose/screens/chat/chat_screen.dart';
import 'package:holdclose/screens/chat/conversation_list_screen.dart';
import 'package:holdclose/screens/home_screen.dart';
import 'package:holdclose/screens/medical/medical_hub_screen.dart';
import 'package:holdclose/services/chat_actions.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/chat_service.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/tab_scaffold.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

Future<Widget> _pumpBar(
  WidgetTester tester, {
  required int currentIndex,
  ValueChanged<int>? onTap,
}) async {
  final Widget bar = TabScaffoldBar(
    currentIndex: currentIndex,
    onDestinationSelected: onTap ?? (_) {},
  );
  // ProviderScope because the bar's inline center mic is a ConsumerWidget
  // (it looks up the container at mount, even though build reads nothing).
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar: bar,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return bar;
}

/// A [ChatLLMBackend] that yields one canned reply — keeps the center-button
/// voice-intent tests off the live shim. The reply text drives the
/// action-vs-chat routing (an `[action:…]` tag → action; prose → chat).
class _ScriptedChatBackend implements ChatLLMBackend {
  const _ScriptedChatBackend(this.reply);

  final String reply;

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    yield ChatDeltaText(reply);
  }
}

/// A [VoiceCapture] returning a canned transcript — no real mic/STT.
class _FakeVoiceCapture implements VoiceCapture {
  const _FakeVoiceCapture(this.transcript);

  final String? transcript;

  @override
  Future<String?> capture({void Function(String partial)? onPartial}) async => transcript;
}

Future<({GoRouter router, ChatRepository repo})> _pumpRouter(
  WidgetTester tester, {
  List<Override> extraOverrides = const <Override>[],
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = buildRouter();
  final DateTime now = DateTime.utc(2026, 5, 30, 12);
  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final ChatRepository repo = ChatRepository(db);
  // ProviderScope wraps the router so the branches that watch riverpod
  // providers (Home → homeConversationProvider, Chat →
  // chatRepositoryProvider) can resolve. Without it, switching to those
  // tabs tears down with "No ProviderScope found".
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        homeConversationProvider.overrideWith(
          (_) async => Conversation(
            id: 'tab-test-conv',
            title: 'Today',
            createdAt: now,
            updatedAt: now,
          ),
        ),
        chatRepositoryProvider.overrideWith((_) => repo),
        ...extraOverrides,
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, repo: repo);
}

String _currentPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

void main() {
  group('TabScaffoldBar — destinations', () {
    test('declares the fixed four tabs (2026-06-06 IA)', () {
      expect(
        TabScaffoldBar.destinations.map((TabScaffoldDestination d) => d.label),
        <String>[
          'Home',
          'Care',
          'Chat',
          'Community',
        ],
      );
    });

    test('Home + Care use the calm Cupertino-style icon set', () {
      expect(TabScaffoldBar.destinations[0].icon, Icons.home_outlined);
      expect(TabScaffoldBar.destinations[0].selectedIcon, Icons.home);
      expect(
        TabScaffoldBar.destinations[1].icon,
        Icons.volunteer_activism_outlined,
      );
      expect(
        TabScaffoldBar.destinations[1].selectedIcon,
        Icons.volunteer_activism,
      );
    });

    test('Chat + Community keep their glyphs', () {
      expect(TabScaffoldBar.destinations[2].icon, Icons.chat_bubble_outline);
      expect(TabScaffoldBar.destinations[2].selectedIcon, Icons.chat_bubble);
      expect(TabScaffoldBar.destinations[3].icon, Icons.forum_outlined);
      expect(TabScaffoldBar.destinations[3].selectedIcon, Icons.forum);
    });
  });

  group('TabScaffold — branch paths', () {
    test('branch paths line up with the fixed four-tab order', () {
      expect(
        TabScaffold.tabBranchPaths,
        <String>[
          '/',
          '/medical',
          '/chat',
          '/community',
        ],
      );
    });

    test('there are exactly as many branch paths as destinations', () {
      expect(
        TabScaffold.tabBranchPaths.length,
        TabScaffoldBar.destinations.length,
      );
    });
  });

  group('TabScaffoldBar — standalone widget', () {
    testWidgets('renders the four tabs spread around the inline center mic',
        (WidgetTester tester) async {
      await _pumpBar(tester, currentIndex: 0);

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Care'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Community'), findsOneWidget);
      // The mic is an inline center action, not a tab.
      expect(find.byKey(TabScaffold.centerVoiceButtonKey), findsOneWidget);
      // The old Medical/Team labels are gone.
      expect(find.text('Medical'), findsNothing);
      expect(find.text('Team'), findsNothing);
    });

    testWidgets('the inline mic sits between Care and Chat (2 left / 2 right)',
        (WidgetTester tester) async {
      await _pumpBar(tester, currentIndex: 0);

      double cx(Finder f) => tester.getCenter(f).dx;
      final double mic = cx(find.byKey(TabScaffold.centerVoiceButtonKey));
      // Home + Care are left of the mic; Chat + Community are right of it.
      expect(cx(find.text('Home')), lessThan(mic));
      expect(cx(find.text('Care')), lessThan(mic));
      expect(cx(find.text('Chat')), greaterThan(mic));
      expect(cx(find.text('Community')), greaterThan(mic));
    });

    testWidgets('forwards taps to onDestinationSelected by branch index',
        (WidgetTester tester) async {
      // Tab order: [Home, Care, Chat, Community] → branch 0..3.
      int? tapped;
      await _pumpBar(
        tester,
        currentIndex: 0,
        onTap: (int index) => tapped = index,
      );

      await tester.tap(find.byIcon(Icons.forum_outlined));
      expect(tapped, 3);

      await tester.tap(find.byIcon(Icons.volunteer_activism_outlined));
      expect(tapped, 1);
    });

    testWidgets(
      'paints the active tab primary and inactive tabs primarySoft',
      (WidgetTester tester) async {
        // Care (branch 1) is active.
        await _pumpBar(tester, currentIndex: 1);

        Color iconColor(IconData glyph) =>
            tester.widget<Icon>(find.byIcon(glyph)).color!;
        // Active tab shows its filled glyph in primary…
        expect(iconColor(Icons.volunteer_activism), holdcloseColors.primary);
        // …inactive tabs show their outlined glyph in primarySoft.
        expect(iconColor(Icons.home_outlined), holdcloseColors.primarySoft);
        expect(
          iconColor(Icons.chat_bubble_outline),
          holdcloseColors.primarySoft,
        );
      },
    );

    testWidgets(
      'currentIndex shows the matching tab\'s filled glyph',
      (WidgetTester tester) async {
        // Chat (branch 2) active → filled chat glyph, no outlined one.
        await _pumpBar(tester, currentIndex: 2);
        expect(find.byIcon(Icons.chat_bubble), findsOneWidget);
        expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      },
    );
  });

  group('TabScaffold — wired via go_router StatefulShellRoute', () {
    testWidgets(
      'tapping each tab switches the shell branch',
      (WidgetTester tester) async {
        final GoRouter router = (await _pumpRouter(tester)).router;

        expect(find.byType(TabScaffold), findsOneWidget);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(_currentPath(router), '/');

        // Care — the tile hub (was "Medical").
        await tester.tap(find.byIcon(Icons.volunteer_activism_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/medical');
        expect(find.byType(MedicalHubScreen), findsOneWidget);

        // Chat — direct landing.
        await tester.tap(find.byIcon(Icons.chat_bubble_outline));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/chat');
        expect(find.byType(ConversationListScreen), findsOneWidget);

        // Community — direct landing.
        await tester.tap(find.byIcon(Icons.forum_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/community');

        // Back to Home.
        await tester.tap(find.byIcon(Icons.home_outlined));
        await tester.pumpAndSettle();
        expect(_currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
      },
    );

    testWidgets(
      're-tapping the active tab pops its branch back to the hub',
      (WidgetTester tester) async {
        final GoRouter router = (await _pumpRouter(tester)).router;

        // Land on the Chat branch and push a thread onto its navigator.
        router.go('/chat');
        await tester.pumpAndSettle();
        expect(find.byType(ConversationListScreen), findsOneWidget);

        unawaited(router.push('/chat/sample-id'));
        await tester.pumpAndSettle();
        expect(find.byType(ConversationListScreen), findsNothing);

        // Re-tap the (now active) Chat tab — its filled glyph is showing.
        await tester.tap(find.byIcon(Icons.chat_bubble));
        await tester.pumpAndSettle();

        expect(
          find.byType(ConversationListScreen),
          findsOneWidget,
          reason: 're-tapping the active tab resets the branch to its hub',
        );
      },
    );
  });

  group('TabScaffold — center voice button (#fb_1780962131440334)', () {
    testWidgets(
      'the bar always shows all four tabs AND the center mic',
      (WidgetTester tester) async {
        await _pumpRouter(tester);

        // Four-tab invariant intact — exactly the four labelled tabs.
        expect(find.text('Home'), findsOneWidget);
        expect(find.text('Care'), findsOneWidget);
        expect(find.text('Chat'), findsOneWidget);
        expect(find.text('Community'), findsOneWidget);
        // The mic is an additive inline center element, not a tab.
        expect(find.byKey(TabScaffold.centerVoiceButtonKey), findsOneWidget);
      },
    );

    testWidgets(
      'a spoken QUESTION routes to a new chat with the coach\'s answer',
      (WidgetTester tester) async {
        final ({GoRouter router, ChatRepository repo}) p = await _pumpRouter(
          tester,
          extraOverrides: <Override>[
            voiceCaptureProvider.overrideWithValue(
              const _FakeVoiceCapture('why is she pacing at night'),
            ),
            // Reply is plain prose (no [action:…]) → routeVoiceIntent opens
            // a chat. chatServiceProvider reads the overridden repo from the
            // graph, so the persisted thread lands in p.repo.
            chatServiceProvider.overrideWith(
              (Ref ref) => ChatService(
                repository: ref.watch(chatRepositoryProvider),
                backend: const _ScriptedChatBackend('A gentle idea.'),
                idFactory: _seqIds(<String>['voice-convo-1', 'u1', 'a1']),
                clock: () => DateTime.utc(2026, 5, 30, 12),
              ),
            ),
          ],
        );

        await tester.tap(find.byKey(TabScaffold.centerVoiceButtonKey));
        // Bounded pumps — CaptionFade's ticker keeps the frame loop busy so
        // pumpAndSettle would time out. Enough frames for capture → route →
        // navigation → render.
        for (int i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // Opened the freshly-minted thread, answer already in place.
        expect(_currentPath(p.router), '/chat/voice-convo-1');
        expect(find.byType(ChatScreen), findsOneWidget);
        final List<Message> persisted =
            await p.repo.loadMessages('voice-convo-1');
        expect(persisted.first.role, MessageRole.user);
        expect(persisted.first.body, 'why is she pacing at night');
        expect(persisted.last.role, MessageRole.assistant);
        expect(persisted.last.body, 'A gentle idea.');
      },
    );

    testWidgets(
      'a spoken COMMAND runs the action + stays put — no chat thread',
      (WidgetTester tester) async {
        Map<String, String>? logged;
        final ({GoRouter router, ChatRepository repo}) p = await _pumpRouter(
          tester,
          extraOverrides: <Override>[
            voiceCaptureProvider.overrideWithValue(
              const _FakeVoiceCapture('log that she did not sleep'),
            ),
            // Reply carries an [action:…] tag → routeVoiceIntent executes it
            // and does NOT navigate.
            chatServiceProvider.overrideWith(
              (Ref ref) => ChatService(
                repository: ref.watch(chatRepositoryProvider),
                backend: const _ScriptedChatBackend(
                  'Logged that she did not sleep.\n'
                  '[action:log_journal occurred_at="just now" '
                  'situation="did not sleep" attempts="none"]',
                ),
                actions: <String, ChatActionExecutor>{
                  'log_journal': (Map<String, String> args) async {
                    logged = args;
                    return null;
                  },
                },
                idFactory: _seqIds(<String>['x1', 'x2', 'x3']),
                clock: () => DateTime.utc(2026, 5, 30, 12),
              ),
            ),
          ],
        );

        await tester.tap(find.byKey(TabScaffold.centerVoiceButtonKey));
        for (int i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // The action ran with the spoken details…
        expect(logged, isNotNull);
        expect(logged!['situation'], 'did not sleep');
        // …and we stayed on Home — no thread was created or navigated to.
        expect(_currentPath(p.router), '/');
        expect(await p.repo.listConversations(), isEmpty);

        // Let the confirmation overlay's auto-dismiss timer fire so no timer
        // is left pending at teardown.
        await tester.pump(const Duration(milliseconds: 2700));
      },
    );

    testWidgets(
      'a blank capture is a no-op — no thread is created or navigated',
      (WidgetTester tester) async {
        final ({GoRouter router, ChatRepository repo}) p = await _pumpRouter(
          tester,
          extraOverrides: <Override>[
            voiceCaptureProvider.overrideWithValue(
              const _FakeVoiceCapture(null),
            ),
          ],
        );

        await tester.tap(find.byKey(TabScaffold.centerVoiceButtonKey));
        await tester.pumpAndSettle();

        // Stayed on Home; no conversation minted.
        expect(_currentPath(p.router), '/');
        expect(await p.repo.listConversations(), isEmpty);
      },
    );
  });
}

/// A sequential id factory — returns the given ids in order, then repeats
/// the last. Lets a test pin the conversation + message ids
/// [ChatService.routeVoiceIntent] mints (it calls idFactory once per row).
ChatIdFactory _seqIds(List<String> ids) {
  int i = 0;
  return () => ids[i < ids.length ? i++ : ids.length - 1];
}

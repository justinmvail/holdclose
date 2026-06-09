import 'dart:async';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/providers/home_conversation_provider.dart';
import 'package:careblazers/providers/voice_capture_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/chat/chat_screen.dart';
import 'package:careblazers/screens/chat/conversation_list_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/chat_service.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/tab_scaffold.dart';
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
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: const SizedBox.shrink(),
      bottomNavigationBar: bar,
    ),
  ));
  await tester.pumpAndSettle();
  return bar;
}

/// A [ChatLLMBackend] that yields a canned reply — keeps the center-button
/// new-chat test off the live shim.
class _FakeChatBackend implements ChatLLMBackend {
  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    yield const ChatDeltaText('A gentle idea.');
  }
}

/// A [VoiceCapture] returning a canned transcript — no real mic/STT.
class _FakeVoiceCapture implements VoiceCapture {
  const _FakeVoiceCapture(this.transcript);

  final String? transcript;

  @override
  Future<String?> capture() async => transcript;
}

Future<({GoRouter router, ChatRepository repo})> _pumpRouter(
  WidgetTester tester, {
  List<Override> extraOverrides = const <Override>[],
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = buildRouter();
  final DateTime now = DateTime.utc(2026, 5, 30, 12);
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
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
    testWidgets('always renders all four NavigationDestinations',
        (WidgetTester tester) async {
      await _pumpBar(tester, currentIndex: 0);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(4));
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Care'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Community'), findsOneWidget);
      // The old Medical/Team labels are gone.
      expect(find.text('Medical'), findsNothing);
      expect(find.text('Team'), findsNothing);
    });

    testWidgets('forwards taps to onDestinationSelected by slot index',
        (WidgetTester tester) async {
      // Bar order: [Home, Care, Chat, Community] → slots 0..3.
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
      'NavigationBarTheme paints active=primary / inactive=primarySoft',
      (WidgetTester tester) async {
        await _pumpBar(tester, currentIndex: 1);

        final BuildContext barContext =
            tester.element(find.byType(NavigationBar));
        final NavigationBarThemeData themeData =
            NavigationBarTheme.of(barContext);

        final IconThemeData selectedIcon = themeData.iconTheme!
            .resolve(<WidgetState>{WidgetState.selected})!;
        final IconThemeData unselectedIcon =
            themeData.iconTheme!.resolve(<WidgetState>{})!;
        expect(selectedIcon.color, careblazersColors.primary);
        expect(unselectedIcon.color, careblazersColors.primarySoft);

        final TextStyle selectedLabel = themeData.labelTextStyle!
            .resolve(<WidgetState>{WidgetState.selected})!;
        final TextStyle unselectedLabel =
            themeData.labelTextStyle!.resolve(<WidgetState>{})!;
        expect(selectedLabel.color, careblazersColors.primary);
        expect(unselectedLabel.color, careblazersColors.primarySoft);
      },
    );

    testWidgets(
      'currentIndex highlights the matching destination',
      (WidgetTester tester) async {
        await _pumpBar(tester, currentIndex: 2);
        expect(
          tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          2,
        );
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

        // Four-tab invariant intact — no fifth destination.
        expect(find.byType(NavigationDestination), findsNWidgets(4));
        expect(find.text('Home'), findsOneWidget);
        expect(find.text('Care'), findsOneWidget);
        expect(find.text('Chat'), findsOneWidget);
        expect(find.text('Community'), findsOneWidget);
        // The mic is an additive docked center element, not a tab.
        expect(find.byKey(TabScaffold.centerVoiceButtonKey), findsOneWidget);
      },
    );

    testWidgets(
      'tapping the center mic starts a new chat and sends the spoken message',
      (WidgetTester tester) async {
        final ({GoRouter router, ChatRepository repo}) p = await _pumpRouter(
          tester,
          extraOverrides: <Override>[
            voiceCaptureProvider.overrideWithValue(
              const _FakeVoiceCapture('why is she pacing at night'),
            ),
            chatLLMBackendProvider.overrideWithValue(_FakeChatBackend()),
            conversationListIdFactoryProvider.overrideWithValue(
              () => 'voice-convo-1',
            ),
            conversationListClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 5, 30, 12),
            ),
          ],
        );

        await tester.tap(find.byKey(TabScaffold.centerVoiceButtonKey));
        // Bounded pumps rather than pumpAndSettle — the assistant reply
        // streams through CaptionFade, whose ticker keeps the frame loop
        // busy (pumpAndSettle would time out). A handful of frames is
        // enough for the capture future, navigation, and auto-send.
        for (int i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // Navigated into the freshly-minted thread.
        expect(_currentPath(p.router), '/chat/voice-convo-1');
        expect(find.byType(ChatScreen), findsOneWidget);

        // The spoken phrase was sent as the first user turn.
        expect(
          find.descendant(
            of: find.byKey(ChatScreen.listKey),
            matching: find.text('why is she pacing at night'),
          ),
          findsOneWidget,
        );
        final List<Message> persisted =
            await p.repo.loadMessages('voice-convo-1');
        expect(persisted.first.role, MessageRole.user);
        expect(persisted.first.body, 'why is she pacing at night');
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
            conversationListIdFactoryProvider.overrideWithValue(
              () => 'should-not-exist',
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

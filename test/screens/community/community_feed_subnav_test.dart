import '../../support/forum_cache_test_override.dart';
import 'dart:async';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/models/forum.dart';
import 'package:holdclose/providers/community_subnav_provider.dart';
import 'package:holdclose/providers/home_conversation_provider.dart';
import 'package:holdclose/routing/router.dart';
import 'package:holdclose/screens/community/community_feed_screen.dart';
import 'package:holdclose/screens/home_screen.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

ForumPost _post(String id, {String? title}) => ForumPost(
      id: id,
      authorId: 'profile-$id',
      title: title ?? 'Post $id',
      body: 'Body of $id',
      createdAt: _fixedNow.subtract(const Duration(hours: 2)),
      updatedAt: _fixedNow.subtract(const Duration(hours: 2)),
      voteCount: 0,
      hidden: false,
      commentCount: 0,
    );

/// Hands back a fixed first page so the Feed segment always renders the
/// same post list — keeps the sub-nav assertions deterministic.
class _CannedForumApiClient extends ForumApiClient {
  _CannedForumApiClient(this._page)
      : super(tokenLoader: _stubTokenLoader, baseUrl: 'https://example.test');

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final List<ForumPost> _page;

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async {
    if (before != null) return const <ForumPost>[];
    return _page;
  }
}

/// Pump the bare [CommunityFeedScreen] (no router) — enough for the
/// in-tab segment-swap + push/pop assertions, which don't depend on the
/// bottom tab bar.
Future<void> _pumpScreen(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(
          _CannedForumApiClient(<ForumPost>[_post('a', title: 'Feed post a')]),
        ),
        communityFeedClockProvider.overrideWithValue(() => _fixedNow),
        forumPostCacheTestOverride(),
      ],
      child: const MaterialApp(home: CommunityFeedScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pump the full tab shell so the Community bottom-tab re-entry behavior
/// can be driven through the real [TabScaffold] wiring. Mirrors the
/// override set in `tab_scaffold_test.dart` (Home needs its conversation
/// provider; Chat needs a repository) plus the forum overrides Community
/// requires.
Future<GoRouter> _pumpShell(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  addTearDown(db.close);

  final GoRouter router = buildRouter(initialLocation: '/community');
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(
          _CannedForumApiClient(<ForumPost>[_post('a', title: 'Feed post a')]),
        ),
        communityFeedClockProvider.overrideWithValue(() => _fixedNow),
        forumPostCacheTestOverride(),
        homeConversationProvider.overrideWith(
          (_) async => Conversation(
            id: 'subnav-test-conv',
            title: 'Today',
            createdAt: _fixedNow,
            updatedAt: _fixedNow,
          ),
        ),
        chatRepositoryProvider.overrideWith((_) => ChatRepository(db)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('Community sub-nav — Phase 14.36', () {
    testWidgets('swaps the in-tab body between Feed, Learn, and Support',
        (WidgetTester tester) async {
      await _pumpScreen(tester);

      // Lands on Feed.
      expect(find.byKey(CommunityFeedScreen.listKey), findsOneWidget);
      expect(find.byKey(CommunityFeedScreen.learnSegmentKey), findsNothing);

      // Feed → Learn.
      await tester.tap(find.text('Learn'));
      await tester.pumpAndSettle();
      expect(find.byKey(CommunityFeedScreen.learnSegmentKey), findsOneWidget);
      expect(find.byKey(CommunityFeedScreen.listKey), findsNothing);
      // The feed-scoped compose FAB drops away off the Feed segment.
      expect(find.byKey(CommunityFeedScreen.composeFabKey), findsNothing);

      // Learn → Support.
      await tester.tap(find.text('Support'));
      await tester.pumpAndSettle();
      expect(find.byKey(CommunityFeedScreen.supportSegmentKey), findsOneWidget);
      expect(find.byKey(CommunityFeedScreen.learnSegmentKey), findsNothing);

      // Support → Feed.
      await tester.tap(find.text('Feed'));
      await tester.pumpAndSettle();
      expect(find.byKey(CommunityFeedScreen.listKey), findsOneWidget);
      expect(find.byKey(CommunityFeedScreen.composeFabKey), findsOneWidget);
    });

    testWidgets('keeps the URL on /community when a segment is swapped',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpShell(tester);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/community',
      );

      await tester.tap(find.text('Learn'));
      await tester.pumpAndSettle();

      expect(find.byKey(CommunityFeedScreen.learnSegmentKey), findsOneWidget);
      // In-tab swap must not touch the route — the whole point of the
      // sub-nav (docs/MENU_LAYOUT_SPEC.md: avoids a 6th tab).
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/community',
      );
    });

    testWidgets('preserves the active segment across a push + pop',
        (WidgetTester tester) async {
      await _pumpScreen(tester);

      await tester.tap(find.text('Learn'));
      await tester.pumpAndSettle();
      expect(find.byKey(CommunityFeedScreen.learnSegmentKey), findsOneWidget);

      // Push a detail route over the screen, then pop back — the feed
      // screen stays mounted underneath, so its local segment state
      // must survive the round-trip.
      final NavigatorState navigator =
          tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Center(child: Text('detail'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);

      navigator.pop();
      await tester.pumpAndSettle();

      expect(
        find.byKey(CommunityFeedScreen.learnSegmentKey),
        findsOneWidget,
        reason: 'a push + pop must not reset the segment',
      );
    });

    testWidgets('re-entering the Community tab resets to the Feed segment',
        (WidgetTester tester) async {
      await _pumpShell(tester);

      // Move off Feed.
      await tester.tap(find.text('Learn'));
      await tester.pumpAndSettle();
      expect(find.byKey(CommunityFeedScreen.learnSegmentKey), findsOneWidget);

      // Switch to the Home tab, then back to Community via the bottom
      // bar — the tab's landing is the Feed segment.
      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);

      await tester.tap(find.byIcon(Icons.forum_outlined));
      await tester.pumpAndSettle();

      expect(
        find.byKey(CommunityFeedScreen.listKey),
        findsOneWidget,
        reason: 're-selecting the Community tab returns to Feed',
      );
      expect(find.byKey(CommunityFeedScreen.learnSegmentKey), findsNothing);
    });
  });

  group('CommunityTabReentry provider', () {
    test('bump increments the monotonic re-entry counter', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(communityTabReentryProvider), 0);
      container.read(communityTabReentryProvider.notifier).bump();
      expect(container.read(communityTabReentryProvider), 1);
      container.read(communityTabReentryProvider.notifier).bump();
      expect(container.read(communityTabReentryProvider), 2);
    });
  });
}

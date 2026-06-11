import 'package:careblazers/models/forum.dart';
import '../../support/forum_cache_test_override.dart';
import 'package:careblazers/screens/community/community_feed_screen.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

class _FakeForumApiClient extends ForumApiClient {
  _FakeForumApiClient({required this.role})
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final String role;

  @override
  Future<ForumProfile> getMyProfile() async => ForumProfile(
        id: 'me',
        careblazersUserId: 'cb-1',
        displayName: 'Me',
        joinedAt: _fixedNow.subtract(const Duration(days: 30)),
        role: role,
      );

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async => const <ForumPost>[];
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeForumApiClient client,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(client),
        communityFeedClockProvider.overrideWithValue(() => _fixedNow),
        forumPostCacheTestOverride(),
      ],
      child: const MaterialApp(home: CommunityFeedScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('CommunityFeedScreen — admin action gate (Phase 13.12)', () {
    testWidgets('non-admin does NOT see the admin action button',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(role: 'user');
      await _pump(tester, client: client);

      expect(find.byKey(CommunityFeedScreen.adminActionKey), findsNothing);
    });

    testWidgets('admin sees the admin action button in the AppBar',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(role: 'admin');
      await _pump(tester, client: client);

      expect(find.byKey(CommunityFeedScreen.adminActionKey), findsOneWidget);
    });

    testWidgets('compose FAB is visible regardless of role',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(role: 'user');
      await _pump(tester, client: client);

      expect(find.byKey(CommunityFeedScreen.composeFabKey), findsOneWidget);
    });
  });
}

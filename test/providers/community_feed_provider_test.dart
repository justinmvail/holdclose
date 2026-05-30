import 'package:careblazers/models/forum.dart';
import 'package:careblazers/providers/community_feed_provider.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

ForumPost _post(String id, {int voteCount = 0, int commentCount = 0}) =>
    ForumPost(
      id: id,
      authorId: 'profile-$id',
      title: 'Post $id',
      body: 'Body of $id',
      createdAt: DateTime.utc(2026, 5, 30, 12),
      updatedAt: DateTime.utc(2026, 5, 30, 12),
      voteCount: voteCount,
      hidden: false,
      commentCount: commentCount,
    );

/// Fake [ForumApiClient] that exposes a stable cursor-aware feed for
/// the notifier-under-test. Each [listPosts] call records its arguments
/// and replies with the slice configured via [setPage].
class _FakeForumApiClient extends ForumApiClient {
  _FakeForumApiClient()
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final List<_ListPostsCall> calls = <_ListPostsCall>[];

  /// Per-(sort, before) page payload. Lookup key is the sort wire value
  /// + the before-cursor (`null` → first page).
  final Map<String, List<ForumPost>> _pages = <String, List<ForumPost>>{};

  /// One-shot throwable. When set, the next [listPosts] call raises it
  /// and clears the slot — lets a test exercise the failure-then-retry
  /// path without permanently wedging the fake.
  Object? nextError;

  void setPage({
    required ForumPostSort sort,
    String? before,
    required List<ForumPost> page,
  }) {
    _pages[_key(sort, before)] = page;
  }

  String _key(ForumPostSort sort, String? before) =>
      '${sort.queryValue}|${before ?? ''}';

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async {
    calls.add(_ListPostsCall(sort: sort, before: before, limit: limit));
    if (nextError != null) {
      final Object err = nextError!;
      nextError = null;
      throw err;
    }
    return _pages[_key(sort, before)] ?? const <ForumPost>[];
  }
}

class _ListPostsCall {
  _ListPostsCall({required this.sort, required this.before, required this.limit});
  final ForumPostSort sort;
  final String? before;
  final int? limit;
}

/// Spin up a [ProviderContainer] wired to [client] and pump the
/// notifier's initial build by reading the provider once.
///
/// [CommunityFeed] is autoDispose (`keepAlive: false`), so a plain
/// `container.read` would let the provider dispose between reads — and
/// the disposed notifier's `state =` becomes a no-op, masking the test
/// signal. A no-op listener keeps the subscription alive for the
/// duration of the test.
ProviderContainer _container(_FakeForumApiClient client) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      forumApiClientProvider.overrideWithValue(client),
    ],
  );
  container.listen<CommunityFeedState>(
    communityFeedProvider,
    (CommunityFeedState? _, CommunityFeedState __) {},
    fireImmediately: true,
  );
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CommunityFeed notifier — Phase 13.10', () {
    test('initial build issues a Hot page-1 request', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(
          sort: ForumPostSort.hot,
          page: <ForumPost>[_post('a'), _post('b')],
        );
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      // Reading the provider triggers build(), which kicks off the
      // first fetch.
      CommunityFeedState state = container.read(communityFeedProvider);
      expect(state.isLoading, isTrue);
      expect(state.posts, isEmpty);

      // Settle the in-flight fetch by yielding the microtask queue.
      await Future<void>.delayed(Duration.zero);

      state = container.read(communityFeedProvider);
      expect(state.isLoading, isFalse);
      expect(state.posts.map((ForumPost p) => p.id).toList(),
          <String>['a', 'b']);
      expect(client.calls, hasLength(1));
      expect(client.calls.single.sort, ForumPostSort.hot);
      expect(client.calls.single.before, isNull);
      expect(client.calls.single.limit, communityFeedPageSize);
    });

    test('setSort reloads page 1 with the new sort key', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(sort: ForumPostSort.hot, page: <ForumPost>[_post('hot-1')])
        ..setPage(sort: ForumPostSort.top, page: <ForumPost>[_post('top-1')]);
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      container.read(communityFeedProvider);
      await Future<void>.delayed(Duration.zero);

      await container.read(communityFeedProvider.notifier)
          .setSort(ForumPostSort.top);

      final CommunityFeedState state = container.read(communityFeedProvider);
      expect(state.sort, ForumPostSort.top);
      expect(state.posts.single.id, 'top-1');
      // Two calls landed total — initial Hot, then Top reload.
      expect(client.calls.map((_ListPostsCall c) => c.sort).toList(),
          <ForumPostSort>[ForumPostSort.hot, ForumPostSort.top]);
    });

    test('setSort to the active sort is a no-op (no reload)', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(sort: ForumPostSort.hot, page: <ForumPost>[_post('a')]);
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      container.read(communityFeedProvider);
      await Future<void>.delayed(Duration.zero);

      await container.read(communityFeedProvider.notifier)
          .setSort(ForumPostSort.hot);

      expect(client.calls, hasLength(1));
    });

    test('loadMore appends the next page anchored on the last post id',
        () async {
      // Full first page (== page size) keeps hasMore=true so loadMore
      // is actually allowed to fire. Use a small page size for the
      // assertion via clipping.
      final List<ForumPost> firstPage = <ForumPost>[
        for (int i = 0; i < communityFeedPageSize; i++) _post('p-$i'),
      ];
      final List<ForumPost> secondPage = <ForumPost>[
        _post('p-$communityFeedPageSize'),
        _post('p-${communityFeedPageSize + 1}'),
      ];
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(sort: ForumPostSort.hot, page: firstPage)
        ..setPage(
          sort: ForumPostSort.hot,
          before: 'p-${communityFeedPageSize - 1}',
          page: secondPage,
        );
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      container.read(communityFeedProvider);
      await Future<void>.delayed(Duration.zero);

      // After the first page, hasMore is true (page == size).
      expect(container.read(communityFeedProvider).hasMore, isTrue);

      await container.read(communityFeedProvider.notifier).loadMore();

      final CommunityFeedState state = container.read(communityFeedProvider);
      expect(state.posts, hasLength(communityFeedPageSize + 2));
      expect(state.posts.last.id, 'p-${communityFeedPageSize + 1}');
      // Second call was paginated.
      expect(client.calls.last.before, 'p-${communityFeedPageSize - 1}');
      // Short page exhausts the cursor.
      expect(state.hasMore, isFalse);
    });

    test('loadMore is a no-op when hasMore is false', () async {
      // First page below the size threshold flips hasMore=false.
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(
          sort: ForumPostSort.hot,
          page: <ForumPost>[_post('a'), _post('b')],
        );
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      container.read(communityFeedProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(communityFeedProvider).hasMore, isFalse);

      await container.read(communityFeedProvider.notifier).loadMore();
      // No second call was issued.
      expect(client.calls, hasLength(1));
    });

    test('loadMore is a no-op when the list is still empty', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(sort: ForumPostSort.hot, page: const <ForumPost>[]);
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      container.read(communityFeedProvider);
      await Future<void>.delayed(Duration.zero);
      await container.read(communityFeedProvider.notifier).loadMore();

      expect(client.calls, hasLength(1));
    });

    test('refresh resets hasMore and reloads page 1', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(
          sort: ForumPostSort.hot,
          page: <ForumPost>[_post('a')],
        );
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      container.read(communityFeedProvider);
      await Future<void>.delayed(Duration.zero);

      // Replace the page so the refresh observes new posts.
      client.setPage(
        sort: ForumPostSort.hot,
        page: <ForumPost>[_post('a'), _post('a-prime')],
      );

      await container.read(communityFeedProvider.notifier).refresh();

      final CommunityFeedState state = container.read(communityFeedProvider);
      expect(state.posts.map((ForumPost p) => p.id).toList(),
          <String>['a', 'a-prime']);
      // Refresh issues an un-paginated call (before=null) on top of the
      // initial fetch.
      expect(client.calls, hasLength(2));
      expect(client.calls.last.before, isNull);
    });

    test('error during initial load surfaces on state.error and leaves '
        'posts empty', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..nextError = Exception('boom');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      container.read(communityFeedProvider);
      await Future<void>.delayed(Duration.zero);

      final CommunityFeedState state = container.read(communityFeedProvider);
      expect(state.error, isNotNull);
      expect(state.posts, isEmpty);
      expect(state.isLoading, isFalse);
    });

    test('refresh after a transient error recovers the feed', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..nextError = Exception('boom')
        ..setPage(sort: ForumPostSort.hot, page: <ForumPost>[_post('a')]);
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      container.read(communityFeedProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(communityFeedProvider).error, isNotNull);

      await container.read(communityFeedProvider.notifier).refresh();

      final CommunityFeedState state = container.read(communityFeedProvider);
      expect(state.error, isNull);
      expect(state.posts.single.id, 'a');
    });
  });

  group('CommunityFeedState equality', () {
    test('two states with identical fields are equal', () {
      final List<ForumPost> posts = <ForumPost>[_post('a')];
      const ForumPostSort sort = ForumPostSort.top;
      expect(
        CommunityFeedState(
          sort: sort,
          posts: posts,
          isLoading: false,
          isLoadingMore: false,
          hasMore: true,
        ),
        CommunityFeedState(
          sort: sort,
          posts: <ForumPost>[_post('a')],
          isLoading: false,
          isLoadingMore: false,
          hasMore: true,
        ),
      );
    });

    test('copyWith(clearError: true) drops the error regardless of '
        'positional default', () {
      const CommunityFeedState before = CommunityFeedState(
        sort: ForumPostSort.hot,
        posts: <ForumPost>[],
        isLoading: false,
        isLoadingMore: false,
        hasMore: true,
        error: 'boom',
      );
      final CommunityFeedState after = before.copyWith(clearError: true);
      expect(after.error, isNull);
    });
  });
}

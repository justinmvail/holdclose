import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/forum.dart';
import '../services/forum_api_client.dart';
import 'forum_post_cache_provider.dart';

part 'community_feed_provider.g.dart';

/// Page size requested from `GET /posts` per scroll batch (BUILD_SPEC.md
/// §13 / Phase 13.10). 20 fills the typical 6-tile viewport plus enough
/// over-scroll that the next-page fetch fires before the caregiver hits
/// the bottom. The Worker clamps anything > 50 server-side, so picking
/// a small constant here keeps the request size predictable across
/// devices.
const int communityFeedPageSize = 20;

/// Immutable snapshot of the community feed (BUILD_SPEC.md §13 / Phase
/// 13.10).
///
/// One state object lets the screen read `sort`, the accumulated `posts`
/// list, paging flags, and any surfaced error without juggling four
/// separate providers. Equality is field-by-field via the [posts]
/// list-equality check so a no-op rebuild (same page reloaded) doesn't
/// trigger a needless `ConsumerWidget.build`.
@immutable
class CommunityFeedState {
  const CommunityFeedState({
    required this.sort,
    required this.posts,
    required this.isLoading,
    required this.isLoadingMore,
    required this.hasMore,
    this.error,
  });

  /// Initial state before the first fetch lands — empty post list, the
  /// default sort (Hot), `isLoading: true` so the screen renders the
  /// skeleton instead of the empty-state placeholder while the network
  /// round-trip is in flight.
  const CommunityFeedState.initial()
      : sort = ForumPostSort.hot,
        posts = const <ForumPost>[],
        isLoading = true,
        isLoadingMore = false,
        hasMore = true,
        error = null;

  final ForumPostSort sort;
  final List<ForumPost> posts;

  /// True while the first page (or a sort-change reload) is in flight.
  /// The screen shows a soft skeleton instead of the empty state during
  /// this window so a slow network doesn't flash "Be the first to post".
  final bool isLoading;

  /// True while a `loadMore()` round-trip is in flight. Separate from
  /// [isLoading] so the screen can render the next-page spinner inline
  /// at the list footer without blanking the already-rendered tiles.
  final bool isLoadingMore;

  /// False once the Worker returns a short page (< [communityFeedPageSize]).
  /// The screen suppresses further `loadMore()` calls when this flips so
  /// scrolling past the bottom doesn't keep firing dead requests.
  final bool hasMore;

  /// Last error surfaced to the screen. Cleared by a successful refresh
  /// / loadMore. Set when the first page fails (so the screen can show a
  /// retry banner) or when a load-more page fails (so the screen can
  /// surface a softer footer error without dumping the existing list).
  final Object? error;

  CommunityFeedState copyWith({
    ForumPostSort? sort,
    List<ForumPost>? posts,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) {
    return CommunityFeedState(
      sort: sort ?? this.sort,
      posts: posts ?? this.posts,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CommunityFeedState) return false;
    return sort == other.sort &&
        isLoading == other.isLoading &&
        isLoadingMore == other.isLoadingMore &&
        hasMore == other.hasMore &&
        error == other.error &&
        listEquals(posts, other.posts);
  }

  @override
  int get hashCode => Object.hash(
        sort,
        isLoading,
        isLoadingMore,
        hasMore,
        error,
        Object.hashAll(posts),
      );
}

/// Backing notifier for the community feed (BUILD_SPEC.md §13 / Phase
/// 13.10).
///
/// Owns the accumulated `posts` list, current `sort`, and the
/// `isLoading / isLoadingMore / hasMore / error` flags the feed screen
/// reads. Three caller-driven verbs:
///
///   * [setSort] — flips the sort key and reloads the first page.
///   * [refresh] — pull-to-refresh; reloads page 1 in place.
///   * [loadMore] — infinite-scroll trigger; appends the next page
///     anchored on the last loaded post's id.
///
/// `keepAlive: false` because the feed only renders while the Community
/// tab is on-screen — leaving the cache primed across tab switches
/// would surface stale posts on return; the brand-voice promise is that
/// the feed reflects what's there *now*, so we re-fetch on remount.
@Riverpod(keepAlive: false)
class CommunityFeed extends _$CommunityFeed {
  @override
  CommunityFeedState build() {
    // Local-first: paint the last-seen page from the on-device cache FIRST
    // (instant + offline), then refresh from the backend. Riverpod handles
    // disposal — `state =` no-ops after teardown via the `mounted` guard.
    unawaited(_init());
    return const CommunityFeedState.initial();
  }

  /// Hydrate from the cache, then refresh page 1 from the backend. The cached
  /// posts render immediately (no skeleton flash, and the whole feed is
  /// readable offline); `isLoading` stays true so the screen still shows it's
  /// refreshing, and a successful load replaces the cache with fresh posts.
  Future<void> _init() async {
    final List<ForumPost> cached = await _readCache(ForumPostSort.hot);
    if (cached.isNotEmpty && _stillHot()) {
      state = state.copyWith(posts: cached);
    }
    await _load(sort: ForumPostSort.hot, append: false);
  }

  bool _stillHot() => state.sort == ForumPostSort.hot && state.posts.isEmpty;

  Future<List<ForumPost>> _readCache(ForumPostSort sort) async {
    try {
      return await ref.read(forumPostCacheRepositoryProvider).firstPage(sort);
    } catch (_) {
      return const <ForumPost>[];
    }
  }

  /// Flip the sort key and reload from the top. No-op when [next] is
  /// already the current sort so a stray re-tap on the active chip
  /// doesn't cause a flicker.
  Future<void> setSort(ForumPostSort next) async {
    if (state.sort == next) return;
    state = state.copyWith(
      sort: next,
      posts: const <ForumPost>[],
      isLoading: true,
      isLoadingMore: false,
      hasMore: true,
      clearError: true,
    );
    await _load(sort: next, append: false);
  }

  /// Pull-to-refresh handler. Always re-runs page 1; preserves the
  /// active [sort]. Errors during refresh surface as a banner but leave
  /// the already-rendered list intact so the screen never blanks under
  /// the caregiver mid-read.
  Future<void> refresh() async {
    state = state.copyWith(
      isLoading: true,
      hasMore: true,
      clearError: true,
    );
    await _load(sort: state.sort, append: false);
  }

  /// Infinite-scroll trigger. Suppresses when there's nothing to load
  /// (empty list, already in flight, exhausted) so the screen can fire
  /// it freely from the scroll listener without race-condition guards.
  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore) return;
    if (!state.hasMore) return;
    if (state.posts.isEmpty) return;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    await _load(sort: state.sort, append: true);
  }

  /// Shared fetch path. [append] = false replaces the list (initial /
  /// refresh / sort-change); [append] = true tacks the new page onto
  /// the existing list (loadMore). The `before` cursor on append is
  /// the last loaded post's id — matches the Worker's `?before=`
  /// pagination shape.
  Future<void> _load({
    required ForumPostSort sort,
    required bool append,
  }) async {
    final ForumApiClient client = ref.read(forumApiClientProvider);
    final String? before = append && state.posts.isNotEmpty
        ? state.posts.last.id
        : null;
    try {
      final List<ForumPost> page = await client.listPosts(
        sort: sort,
        before: before,
        limit: communityFeedPageSize,
      );
      final List<ForumPost> merged = append
          ? <ForumPost>[...state.posts, ...page]
          : page;
      state = state.copyWith(
        sort: sort,
        posts: merged,
        isLoading: false,
        isLoadingMore: false,
        hasMore: page.length >= communityFeedPageSize,
        clearError: true,
      );
      // Cache the fresh first page so the next cold/offline open shows it.
      if (!append) {
        unawaited(_writeCache(sort, page));
      }
    } catch (error) {
      // Offline / backend down. Local-first: prefer showing CONTENT over an
      // error. On a first-page load, keep whatever's already on screen, or
      // fall back to the cached first page, so the feed stays readable with no
      // signal. Only surface the error when there's genuinely nothing to show.
      if (!append) {
        List<ForumPost> show = state.posts;
        if (show.isEmpty) show = await _readCache(sort);
        if (show.isNotEmpty) {
          state = state.copyWith(
            sort: sort,
            posts: show,
            isLoading: false,
            isLoadingMore: false,
            clearError: true,
          );
          return;
        }
      }
      state = state.copyWith(
        isLoading: false,
        isLoadingMore: false,
        error: error,
      );
    }
  }

  Future<void> _writeCache(ForumPostSort sort, List<ForumPost> page) async {
    try {
      await ref.read(forumPostCacheRepositoryProvider).cacheFirstPage(sort, page);
    } catch (_) {
      // A cache write failure must never affect the live feed.
    }
  }
}

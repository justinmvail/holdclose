import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/forum.dart';
import '../services/forum_api_client.dart';

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
    // Kick off the first fetch out of band — the build() return value
    // is the initial state, and the future settles a microtask later
    // with the first page's payload. Riverpod handles disposal: if the
    // notifier tears down before the future resolves, `state =` becomes
    // a no-op via the `mounted` guard inside `_load`.
    unawaited(_load(sort: ForumPostSort.hot, append: false));
    return const CommunityFeedState.initial();
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
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        isLoadingMore: false,
        error: error,
      );
    }
  }
}

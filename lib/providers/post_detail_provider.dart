import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/forum.dart';
import '../services/forum_api_client.dart';

part 'post_detail_provider.g.dart';

/// Immutable snapshot the post-detail screen renders off of
/// (BUILD_SPEC.md §13 / Phase 13.11).
///
/// Tracks the loaded post + its flat comment list plus the small set of
/// transient flags the screen needs:
///
///   * [isLoading] — true while the initial load (or a refresh) is in
///     flight. The screen shows a soft skeleton instead of the empty
///     "Be the first to reply" placeholder so a slow round-trip doesn't
///     flash misleading copy.
///   * [postingReplyKeys] — set of parent ids that currently have an
///     outbound reply in flight. Root-level replies use the empty
///     string as a key so the reply input under the post body can also
///     surface a spinner. Stored as a set so concurrent replies to
///     different parents don't blow each other away.
///   * [pendingVotes] — local optimistic vote values keyed by
///     `<kind>:<id>` (e.g. `comment:abc`, `post:xyz`). Used so the
///     up/down arrows can highlight before the API round-trip lands.
///   * [error] — last surfaced error. Cleared by a successful
///     refresh / reply.
@immutable
class PostDetailState {
  const PostDetailState({
    required this.postId,
    required this.post,
    required this.comments,
    required this.isLoading,
    required this.postingReplyKeys,
    required this.pendingVotes,
    this.error,
  });

  const PostDetailState.empty()
      : postId = '',
        post = null,
        comments = const <ForumComment>[],
        isLoading = false,
        postingReplyKeys = const <String>{},
        pendingVotes = const <String, int>{},
        error = null;

  const PostDetailState.loading(this.postId, {ForumPost? initialPost})
      : post = initialPost,
        comments = const <ForumComment>[],
        isLoading = true,
        postingReplyKeys = const <String>{},
        pendingVotes = const <String, int>{},
        error = null;

  final String postId;
  final ForumPost? post;
  final List<ForumComment> comments;
  final bool isLoading;
  final Set<String> postingReplyKeys;
  final Map<String, int> pendingVotes;
  final Object? error;

  /// Reply-input key for [parentCommentId]. Root-level replies key off
  /// the empty string so the post-level reply input has a stable
  /// identity in [postingReplyKeys] / handlers.
  static String replyKey(String? parentCommentId) =>
      parentCommentId ?? '';

  /// Pending-vote map key for a target. Mirrors the
  /// `target_kind`/`target_id` shape the Worker accepts so flipping
  /// between the two is mechanical.
  static String voteKey(ForumVoteTarget kind, String targetId) =>
      '${kind.queryValue}:$targetId';

  PostDetailState copyWith({
    String? postId,
    ForumPost? post,
    List<ForumComment>? comments,
    bool? isLoading,
    Set<String>? postingReplyKeys,
    Map<String, int>? pendingVotes,
    Object? error,
    bool clearError = false,
    bool clearPost = false,
  }) {
    return PostDetailState(
      postId: postId ?? this.postId,
      post: clearPost ? null : (post ?? this.post),
      comments: comments ?? this.comments,
      isLoading: isLoading ?? this.isLoading,
      postingReplyKeys: postingReplyKeys ?? this.postingReplyKeys,
      pendingVotes: pendingVotes ?? this.pendingVotes,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PostDetailState) return false;
    return postId == other.postId &&
        post == other.post &&
        isLoading == other.isLoading &&
        error == other.error &&
        listEquals(comments, other.comments) &&
        setEquals(postingReplyKeys, other.postingReplyKeys) &&
        mapEquals(pendingVotes, other.pendingVotes);
  }

  @override
  int get hashCode => Object.hash(
        postId,
        post,
        isLoading,
        error,
        Object.hashAll(comments),
        Object.hashAll(postingReplyKeys),
        Object.hashAll(
          pendingVotes.entries.map(
            (MapEntry<String, int> e) => Object.hash(e.key, e.value),
          ),
        ),
      );
}

/// Backing notifier for the post-detail screen (BUILD_SPEC.md §13 /
/// Phase 13.11).
///
/// Owns the loaded post, its comment list, and the optimistic-vote +
/// in-flight-reply bookkeeping. The screen drives loads through [load]
/// (called once from `initState`); the notifier itself stays
/// post-agnostic so a single instance can be reused across navigations
/// without a family-key indirection.
///
/// `keepAlive: false` because the post-detail screen is pushed onto the
/// root navigator — when the route pops, the provider disposes and the
/// next visit re-fetches. Holding the cached tree across navigation
/// would surface stale comment counts the moment another caregiver
/// replied.
@Riverpod(keepAlive: false)
class PostDetail extends _$PostDetail {
  @override
  PostDetailState build() => const PostDetailState.empty();

  /// Initial load. Called by the screen's `initState`; subsequent
  /// invocations for the same [postId] no-op so a rebuild doesn't
  /// thrash the in-flight network call. Pass [initialPost] when the
  /// caller already has the post in hand (e.g. nav from the feed) so
  /// the screen can render the header immediately instead of blanking
  /// while the post fetch lands.
  Future<void> load(
    String postId, {
    ForumPost? initialPost,
  }) async {
    if (state.postId == postId && (state.post != null || state.isLoading)) {
      return;
    }
    state = PostDetailState.loading(postId, initialPost: initialPost);
    await _fetch(postId, fetchPost: initialPost == null);
  }

  /// Pull-to-refresh handler. Re-reads the post + comments for the
  /// already-loaded [PostDetailState.postId]; no-op when no post id is
  /// in scope yet.
  Future<void> refresh() async {
    final String postId = state.postId;
    if (postId.isEmpty) return;
    state = state.copyWith(isLoading: true, clearError: true);
    await _fetch(postId, fetchPost: true);
  }

  Future<void> _fetch(String postId, {required bool fetchPost}) async {
    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      final ForumPost post = fetchPost
          ? await client.getPost(postId)
          : state.post!;
      final List<ForumComment> comments = await client.listComments(
        postId: postId,
      );
      state = state.copyWith(
        postId: postId,
        post: post,
        comments: comments,
        isLoading: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        postId: postId,
        isLoading: false,
        error: error,
      );
    }
  }

  /// Cast a vote on the post itself or a comment. Optimistically flips
  /// the local [PostDetailState.pendingVotes] entry so the up/down
  /// arrows highlight immediately; reverts on API failure.
  ///
  /// [value] must be -1, 0, or +1; 0 withdraws an existing vote.
  Future<void> vote({
    required ForumVoteTarget targetKind,
    required String targetId,
    required int value,
  }) async {
    assert(
      value == -1 || value == 0 || value == 1,
      'vote value must be -1, 0, or +1 (got $value)',
    );
    final String key = PostDetailState.voteKey(targetKind, targetId);
    final Map<String, int> nextPending = Map<String, int>.of(state.pendingVotes)
      ..[key] = value;
    state = state.copyWith(pendingVotes: nextPending);

    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      final ForumVoteResponse result = await client.castVote(
        targetKind: targetKind,
        targetId: targetId,
        value: value,
      );
      _applyVoteResult(targetKind, targetId, result, key);
    } catch (error) {
      // Revert the optimistic flip on failure so the arrows match the
      // canonical server-side count.
      final Map<String, int> rolled = Map<String, int>.of(state.pendingVotes)
        ..remove(key);
      state = state.copyWith(pendingVotes: rolled, error: error);
    }
  }

  void _applyVoteResult(
    ForumVoteTarget kind,
    String id,
    ForumVoteResponse result,
    String pendingKey,
  ) {
    final Map<String, int> pending = Map<String, int>.of(state.pendingVotes)
      ..[pendingKey] = result.value;
    if (kind == ForumVoteTarget.post) {
      final ForumPost? post = state.post;
      if (post != null && post.id == id) {
        state = state.copyWith(
          post: post.copyWith(voteCount: result.voteCount),
          pendingVotes: pending,
        );
      } else {
        state = state.copyWith(pendingVotes: pending);
      }
      return;
    }
    final List<ForumComment> next = state.comments
        .map((ForumComment c) =>
            c.id == id ? c.copyWith(voteCount: result.voteCount) : c)
        .toList(growable: false);
    state = state.copyWith(comments: next, pendingVotes: pending);
  }

  /// Submit a reply. [parentCommentId] is null for a root-level
  /// (post-level) comment. On success the new comment is appended to
  /// the local list so the thread re-renders without a full refetch.
  Future<ForumCreateCommentResponse?> reply({
    String? parentCommentId,
    required String body,
  }) async {
    final String postId = state.postId;
    if (postId.isEmpty) return null;
    final String key = PostDetailState.replyKey(parentCommentId);
    final Set<String> nextKeys = <String>{...state.postingReplyKeys, key};
    state = state.copyWith(postingReplyKeys: nextKeys, clearError: true);

    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      final ForumCreateCommentResponse resp = await client.createComment(
        postId: postId,
        body: body,
        parentCommentId: parentCommentId,
      );
      final List<ForumComment> nextComments = <ForumComment>[
        ...state.comments,
        resp.comment,
      ];
      final Set<String> done = <String>{...state.postingReplyKeys}..remove(key);
      state = state.copyWith(
        comments: nextComments,
        postingReplyKeys: done,
      );
      return resp;
    } catch (error) {
      final Set<String> done = <String>{...state.postingReplyKeys}..remove(key);
      state = state.copyWith(
        postingReplyKeys: done,
        error: error,
      );
      return null;
    }
  }

  /// File a report. Returns true when the Worker accepts the report;
  /// false on transport / 4xx / 5xx so the screen can surface the
  /// failure without rolling back any UI state (a report has no
  /// optimistic counterpart).
  Future<bool> report({
    required ForumVoteTarget targetKind,
    required String targetId,
    required String reason,
  }) async {
    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      await client.submitReport(
        targetKind: targetKind,
        targetId: targetId,
        reason: reason,
      );
      return true;
    } catch (error) {
      state = state.copyWith(error: error);
      return false;
    }
  }
}

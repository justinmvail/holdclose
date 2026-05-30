import 'dart:math' as math;

import '../models/forum.dart';
import 'forum_api_client.dart';

/// Deterministic in-memory [ForumApiClient] used in demo mode
/// (home-refactor follow-up). Lets a TestFlight or Play Store build
/// run the community surfaces without a deployed Cloudflare Worker —
/// the caregiver sees seed posts, can write their own, comment, vote,
/// and toggle off in Settings once the real backend is wired.
///
/// State lives in process memory only — nothing persists across app
/// restarts. That's the right shape for a "demo" toggle: the surface
/// always opens to the same seeded conversation rather than
/// accumulating stale drafts.
class FakeForumApiClient extends ForumApiClient {
  FakeForumApiClient({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now,
        super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://demo.invalid',
        ) {
    _seedDemoData();
  }

  static Future<String> _stubTokenLoader() async => 'demo-fake-token';

  final DateTime Function() _clock;
  final math.Random _rng = math.Random(7);

  final Map<String, ForumProfile> _profiles = <String, ForumProfile>{};
  final List<ForumPost> _posts = <ForumPost>[];
  final Map<String, List<ForumComment>> _commentsByPost =
      <String, List<ForumComment>>{};
  final Map<String, int> _votes = <String, int>{};
  final List<ForumReport> _reports = <ForumReport>[];

  /// The synthetic profile the demo signs in as. The fake auth
  /// provider's user maps to `careblazers_user_id = 'demo-user'`.
  static const String _demoUserCareblazersId = 'demo-user';
  static const String _demoProfileId = 'demo-profile';

  void _seedDemoData() {
    final DateTime now = _clock();
    _profiles[_demoUserCareblazersId] = ForumProfile(
      id: _demoProfileId,
      careblazersUserId: _demoUserCareblazersId,
      displayName: 'You',
      joinedAt: now.subtract(const Duration(days: 60)),
      role: 'user',
    );

    final ForumProfile sarah = ForumProfile(
      id: 'profile-sarah',
      careblazersUserId: 'seed-sarah',
      displayName: 'Sarah H.',
      joinedAt: now.subtract(const Duration(days: 320)),
      role: 'user',
    );
    final ForumProfile mei = ForumProfile(
      id: 'profile-mei',
      careblazersUserId: 'seed-mei',
      displayName: 'Mei W.',
      joinedAt: now.subtract(const Duration(days: 210)),
      role: 'user',
    );
    final ForumProfile rob = ForumProfile(
      id: 'profile-rob',
      careblazersUserId: 'seed-rob',
      displayName: 'Rob D.',
      joinedAt: now.subtract(const Duration(days: 90)),
      role: 'user',
    );
    _profiles[sarah.careblazersUserId] = sarah;
    _profiles[mei.careblazersUserId] = mei;
    _profiles[rob.careblazersUserId] = rob;

    _seedPost(
      author: sarah,
      title: 'Sundowning is wrecking us at 5pm sharp',
      body: "Mom's been doing this thing where right at 5 she gets "
          "convinced we're in the wrong house. I've started turning "
          "every light on around 4 and it helps a little. Anyone else?",
      ageHours: 5,
      voteCount: 12,
      commentCount: 3,
    );
    _seedPost(
      author: mei,
      title: 'A script that worked: "Mom went to the store"',
      body: "When dad asks for his mother (she's been gone 22 years) "
          "I used to gently correct him. Last week I tried 'she went to "
          "the store, she'll be back soon' and he relaxed completely.",
      ageHours: 21,
      voteCount: 27,
      commentCount: 5,
    );
    _seedPost(
      author: rob,
      title: 'Refusing to take the new med — any tricks?',
      body: "The neurologist swapped one of dad's meds two weeks ago "
          "and he flat refuses to take the new one. He used to be fine "
          "with pills. The doctor says it's the same active ingredient. "
          "Anyone hit this?",
      ageHours: 48,
      voteCount: 8,
      commentCount: 7,
    );
  }

  void _seedPost({
    required ForumProfile author,
    required String title,
    required String body,
    required int ageHours,
    required int voteCount,
    required int commentCount,
  }) {
    final DateTime now = _clock();
    final DateTime created = now.subtract(Duration(hours: ageHours));
    final String id = 'seed-post-${_posts.length + 1}';
    _posts.add(ForumPost(
      id: id,
      authorId: author.id,
      title: title,
      body: body,
      createdAt: created,
      updatedAt: created,
      voteCount: voteCount,
      hidden: false,
      commentCount: commentCount,
    ));
    _commentsByPost[id] = <ForumComment>[];
  }

  String _mintId(String prefix) =>
      '$prefix-${_clock().millisecondsSinceEpoch}-${_rng.nextInt(1 << 32)}';

  ForumProfile _resolveMyProfile() {
    final ForumProfile? p = _profiles[_demoUserCareblazersId];
    if (p != null) return p;
    final ForumProfile fresh = ForumProfile(
      id: _demoProfileId,
      careblazersUserId: _demoUserCareblazersId,
      displayName: 'You',
      joinedAt: _clock(),
      role: 'user',
    );
    _profiles[_demoUserCareblazersId] = fresh;
    return fresh;
  }

  // ---- Profile endpoints -------------------------------------------------

  @override
  Future<ForumProfile> bootstrapProfile() async => _resolveMyProfile();

  @override
  Future<ForumProfile> getMyProfile() async => _resolveMyProfile();

  @override
  Future<ForumProfile> updateMyProfile({
    String? displayName,
    String? avatarUrl,
  }) async {
    final ForumProfile current = _resolveMyProfile();
    final ForumProfile next = ForumProfile(
      id: current.id,
      careblazersUserId: current.careblazersUserId,
      displayName: displayName ?? current.displayName,
      avatarUrl: avatarUrl ?? current.avatarUrl,
      joinedAt: current.joinedAt,
      role: current.role,
    );
    _profiles[current.careblazersUserId] = next;
    return next;
  }

  @override
  Future<ForumPublicProfile> getPublicProfile(String profileId) async {
    final ForumProfile? match = _profiles.values
        .where((ForumProfile p) => p.id == profileId)
        .firstOrNull;
    if (match == null) {
      throw ForumApiException(statusCode: 404, error: 'not_found');
    }
    final int posts = _posts.where((ForumPost p) => p.authorId == match.id)
        .length;
    final int comments = _commentsByPost.values
        .expand((List<ForumComment> cs) => cs)
        .where((ForumComment c) => c.authorId == match.id)
        .length;
    return ForumPublicProfile(
      id: match.id,
      displayName: match.displayName,
      avatarUrl: match.avatarUrl,
      joinedAt: match.joinedAt,
      postCount: posts,
      commentCount: comments,
    );
  }

  // ---- Posts -------------------------------------------------------------

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async {
    final List<ForumPost> visible =
        _posts.where((ForumPost p) => !p.hidden).toList();
    switch (sort) {
      case ForumPostSort.hot:
        visible.sort((ForumPost a, ForumPost b) {
          final int byVotes = b.voteCount.compareTo(a.voteCount);
          if (byVotes != 0) return byVotes;
          return b.createdAt.compareTo(a.createdAt);
        });
      case ForumPostSort.newest:
        visible.sort((ForumPost a, ForumPost b) =>
            b.createdAt.compareTo(a.createdAt));
      case ForumPostSort.top:
        visible.sort((ForumPost a, ForumPost b) =>
            b.voteCount.compareTo(a.voteCount));
    }
    final int start = before == null
        ? 0
        : visible.indexWhere((ForumPost p) => p.id == before) + 1;
    final int end = limit == null
        ? visible.length
        : math.min(visible.length, start + limit);
    return visible.sublist(start, end);
  }

  @override
  Future<ForumPost> getPost(String postId) async {
    final ForumPost? match =
        _posts.where((ForumPost p) => p.id == postId).firstOrNull;
    if (match == null) {
      throw ForumApiException(statusCode: 404, error: 'not_found');
    }
    return match;
  }

  @override
  Future<ForumCreatePostResponse> createPost({
    required String title,
    required String body,
  }) async {
    final ForumProfile me = _resolveMyProfile();
    final DateTime now = _clock();
    final ForumPost post = ForumPost(
      id: _mintId('post'),
      authorId: me.id,
      title: title,
      body: body,
      createdAt: now,
      updatedAt: now,
      voteCount: 0,
      hidden: false,
      commentCount: 0,
    );
    _posts.insert(0, post);
    _commentsByPost[post.id] = <ForumComment>[];
    return ForumCreatePostResponse(post: post);
  }

  @override
  Future<ForumPost> updatePost({
    required String postId,
    required String body,
  }) async {
    final int idx = _posts.indexWhere((ForumPost p) => p.id == postId);
    if (idx < 0) {
      throw ForumApiException(statusCode: 404, error: 'not_found');
    }
    final ForumPost current = _posts[idx];
    final ForumPost next = ForumPost(
      id: current.id,
      authorId: current.authorId,
      title: current.title,
      body: body,
      createdAt: current.createdAt,
      updatedAt: _clock(),
      voteCount: current.voteCount,
      hidden: current.hidden,
      commentCount: current.commentCount,
    );
    _posts[idx] = next;
    return next;
  }

  @override
  Future<void> deletePost(String postId) async {
    _posts.removeWhere((ForumPost p) => p.id == postId);
    _commentsByPost.remove(postId);
  }

  // ---- Comments ----------------------------------------------------------

  @override
  Future<List<ForumComment>> listComments({
    required String postId,
    ForumCommentSort sort = ForumCommentSort.top,
  }) async {
    final List<ForumComment> rows =
        _commentsByPost[postId]?.toList() ?? <ForumComment>[];
    switch (sort) {
      case ForumCommentSort.top:
        rows.sort((ForumComment a, ForumComment b) =>
            b.voteCount.compareTo(a.voteCount));
      case ForumCommentSort.newest:
        rows.sort((ForumComment a, ForumComment b) =>
            b.createdAt.compareTo(a.createdAt));
    }
    return rows;
  }

  @override
  Future<ForumCreateCommentResponse> createComment({
    required String postId,
    required String body,
    String? parentCommentId,
  }) async {
    final ForumProfile me = _resolveMyProfile();
    final int parentDepth = parentCommentId == null
        ? -1
        : _commentsByPost[postId]
                ?.firstWhere(
                    (ForumComment c) => c.id == parentCommentId,
                    orElse: () => _placeholderComment(postId))
                .depth ??
            0;
    final ForumComment comment = ForumComment(
      id: _mintId('comment'),
      postId: postId,
      parentCommentId: parentCommentId,
      authorId: me.id,
      body: body,
      createdAt: _clock(),
      voteCount: 0,
      depth: parentDepth + 1,
      hidden: false,
    );
    _commentsByPost.putIfAbsent(postId, () => <ForumComment>[]).add(comment);
    // Bump the post's denormalized comment counter so the feed tile
    // updates without a refetch.
    final int idx = _posts.indexWhere((ForumPost p) => p.id == postId);
    if (idx >= 0) {
      final ForumPost current = _posts[idx];
      _posts[idx] = ForumPost(
        id: current.id,
        authorId: current.authorId,
        title: current.title,
        body: current.body,
        createdAt: current.createdAt,
        updatedAt: current.updatedAt,
        voteCount: current.voteCount,
        hidden: current.hidden,
        commentCount: current.commentCount + 1,
      );
    }
    return ForumCreateCommentResponse(comment: comment);
  }

  ForumComment _placeholderComment(String postId) => ForumComment(
        id: 'missing',
        postId: postId,
        createdAt: _clock(),
        voteCount: 0,
        depth: 0,
        hidden: true,
      );

  @override
  Future<void> deleteComment(String commentId) async {
    for (final MapEntry<String, List<ForumComment>> e
        in _commentsByPost.entries) {
      e.value.removeWhere((ForumComment c) => c.id == commentId);
    }
  }

  // ---- Votes -------------------------------------------------------------

  @override
  Future<ForumVoteResponse> castVote({
    required ForumVoteTarget targetKind,
    required String targetId,
    required int value,
  }) async {
    assert(value == -1 || value == 0 || value == 1);
    final String key = '${targetKind.queryValue}|$targetId';
    final int prior = _votes[key] ?? 0;
    final int delta = value - prior;
    _votes[key] = value;

    if (targetKind == ForumVoteTarget.post) {
      final int idx = _posts.indexWhere((ForumPost p) => p.id == targetId);
      if (idx >= 0) {
        final ForumPost current = _posts[idx];
        _posts[idx] = ForumPost(
          id: current.id,
          authorId: current.authorId,
          title: current.title,
          body: current.body,
          createdAt: current.createdAt,
          updatedAt: current.updatedAt,
          voteCount: current.voteCount + delta,
          hidden: current.hidden,
          commentCount: current.commentCount,
        );
        return ForumVoteResponse(
          voteCount: _posts[idx].voteCount,
          value: value,
        );
      }
    } else {
      for (final MapEntry<String, List<ForumComment>> e
          in _commentsByPost.entries) {
        final int idx =
            e.value.indexWhere((ForumComment c) => c.id == targetId);
        if (idx >= 0) {
          final ForumComment current = e.value[idx];
          e.value[idx] = ForumComment(
            id: current.id,
            postId: current.postId,
            parentCommentId: current.parentCommentId,
            authorId: current.authorId,
            body: current.body,
            createdAt: current.createdAt,
            voteCount: current.voteCount + delta,
            depth: current.depth,
            hidden: current.hidden,
          );
          return ForumVoteResponse(
            voteCount: e.value[idx].voteCount,
            value: value,
          );
        }
      }
    }
    return ForumVoteResponse(voteCount: 0, value: value);
  }

  // ---- Reports -----------------------------------------------------------

  @override
  Future<ForumReport> submitReport({
    required ForumVoteTarget targetKind,
    required String targetId,
    required String reason,
  }) async {
    final ForumProfile me = _resolveMyProfile();
    final ForumReport report = ForumReport(
      id: _mintId('report'),
      targetKind: targetKind.queryValue,
      targetId: targetId,
      reporterId: me.id,
      reason: reason,
      status: 'pending',
      createdAt: _clock(),
    );
    _reports.add(report);
    return report;
  }

  @override
  Future<List<ForumReport>> listReports({String? status}) async {
    return _reports
        .where((ForumReport r) => status == null || r.status == status)
        .toList(growable: false);
  }

  @override
  Future<ForumReportReviewResponse> reviewReport({
    required String reportId,
    required ForumReportAction action,
  }) async {
    final int idx = _reports.indexWhere((ForumReport r) => r.id == reportId);
    if (idx < 0) {
      throw ForumApiException(statusCode: 404, error: 'not_found');
    }
    final ForumReport current = _reports[idx];
    final ForumReport resolved = ForumReport(
      id: current.id,
      targetKind: current.targetKind,
      targetId: current.targetId,
      reporterId: current.reporterId,
      reason: current.reason,
      status: 'actioned',
      createdAt: current.createdAt,
      resolvedAt: _clock(),
    );
    _reports[idx] = resolved;
    return ForumReportReviewResponse(
      report: resolved,
      action: action.queryValue,
      bannedUserId:
          action == ForumReportAction.banUser ? 'demo-banned' : null,
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

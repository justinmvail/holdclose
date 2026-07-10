import 'dart:convert';
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
  FakeForumApiClient({DateTime Function()? clock, FakeForumBackend? backend})
      : _clock = clock ?? DateTime.now,
        _backend = backend ?? FakeForumBackend(),
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

  // Care-circle connect (2026-06-06). Lowercased `@handle` → profile id,
  // the circles the demo user belongs to, and the live invites mapped by
  // token. All in-process so tests/demo never hit the network.
  final Map<String, String> _usernameRegistry = <String, String>{};

  /// Circle + sync state. Held in a separate [FakeForumBackend] so a
  /// "two device" test can construct two [FakeForumApiClient]s over one
  /// shared backend (server-authoritative sync) — device A pushes,
  /// device B pulls, both through the same circles + sync store. A fake
  /// constructed without one gets its own private backend (the demo /
  /// single-device default).
  final FakeForumBackend _backend;

  List<CircleDto> get _circles => _backend.circles;
  Map<String, _FakeInvite> get _invites => _backend.invites;
  Map<String, _FakeCircleSync> get _sync => _backend.sync;

  /// Matches the Worker's `^[a-z0-9_]{3,20}$` rule.
  static final RegExp _usernamePattern = RegExp(r'^[a-z0-9_]{3,20}$');

  /// The synthetic profile the demo signs in as. The fake auth
  /// provider's user maps to `careblazers_user_id = 'demo-user'`.
  static const String _demoUserHoldcloseId = 'demo-user';
  static const String _demoProfileId = 'demo-profile';

  void _seedDemoData() {
    final DateTime now = _clock();
    _profiles[_demoUserHoldcloseId] = ForumProfile(
      id: _demoProfileId,
      careblazersUserId: _demoUserHoldcloseId,
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
    final ForumProfile? p = _profiles[_demoUserHoldcloseId];
    if (p != null) return p;
    final ForumProfile fresh = ForumProfile(
      id: _demoProfileId,
      careblazersUserId: _demoUserHoldcloseId,
      displayName: 'You',
      joinedAt: _clock(),
      role: 'user',
    );
    _profiles[_demoUserHoldcloseId] = fresh;
    return fresh;
  }

  // ---- Billing endpoints -------------------------------------------------
  //
  // The demo/no-backend build never grants premium from THIS client — the
  // fake billing service (isPremium=true) is what the demo uses. These
  // overrides just keep the fake self-consistent (no network) if something
  // reaches for them: verify/read both report the free baseline.

  @override
  Future<ServerEntitlement> verifyPurchase({
    required String platform,
    required String productId,
    required String receipt,
  }) async =>
      ServerEntitlement.free;

  @override
  Future<ServerEntitlement> getEntitlement() async => ServerEntitlement.free;

  // ---- Profile endpoints -------------------------------------------------

  @override
  Future<ForumProfile> bootstrapProfile() async => _resolveMyProfile();

  @override
  Future<ForumProfile> getMyProfile() async => _resolveMyProfile();

  @override
  Future<ForumProfile> updateMyProfile({
    String? displayName,
    String? avatarUrl,
    String? username,
  }) async {
    final ForumProfile current = _resolveMyProfile();
    String? nextUsername = current.username;
    if (username != null) {
      final String handle = username.toLowerCase();
      if (!_usernamePattern.hasMatch(handle)) {
        throw ForumApiException(statusCode: 400, error: 'invalid_username');
      }
      final String? holder = _usernameRegistry[handle];
      if (holder != null && holder != current.id) {
        throw ForumApiException(statusCode: 409, error: 'username_taken');
      }
      // Release any handle the demo user previously held, then claim.
      if (current.username != null) {
        _usernameRegistry.remove(current.username);
      }
      _usernameRegistry[handle] = current.id;
      nextUsername = handle;
    }
    final ForumProfile next = ForumProfile(
      id: current.id,
      careblazersUserId: current.careblazersUserId,
      displayName: displayName ?? current.displayName,
      avatarUrl: avatarUrl ?? current.avatarUrl,
      joinedAt: current.joinedAt,
      role: current.role,
      username: nextUsername,
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
      username: match.username,
    );
  }

  // ---- Username + circles (care-circle connect, 2026-06-06) --------------

  @override
  Future<({bool valid, bool available})> usernameAvailable(
    String handle,
  ) async {
    final String h = handle.toLowerCase();
    final bool valid = _usernamePattern.hasMatch(h);
    if (!valid) return (valid: false, available: false);
    final ForumProfile me = _resolveMyProfile();
    final String? holder = _usernameRegistry[h];
    // The caller's own current handle counts as available to them.
    final bool available = holder == null || holder == me.id;
    return (valid: true, available: available);
  }

  @override
  Future<ForumPublicProfile> getProfileByUsername(String username) async {
    final String? profileId = _usernameRegistry[username.toLowerCase()];
    final ForumProfile? match = profileId == null
        ? null
        : _profiles.values
            .where((ForumProfile p) => p.id == profileId)
            .firstOrNull;
    if (match == null) {
      throw ForumApiException(statusCode: 404, error: 'profile_not_found');
    }
    return ForumPublicProfile(
      id: match.id,
      displayName: match.displayName,
      avatarUrl: match.avatarUrl,
      username: match.username,
    );
  }

  @override
  Future<CircleDto> createCircle(
    String name, {
    SyncPatientWrite? patient,
  }) async {
    final ForumProfile me = _resolveMyProfile();
    final String circleId = _mintId('circle');
    final _FakeCircleSync sync = _FakeCircleSync();
    _sync[circleId] = sync;
    SyncPatient? syncPatient;
    if (patient != null) {
      syncPatient = sync.upsertPatient(
        payload: jsonEncode(patient.payload),
        clientUpdatedAt: patient.clientUpdatedAt,
        deleted: patient.deleted,
      );
    }
    final CircleDto circle = CircleDto(
      id: circleId,
      name: name,
      ownerProfileId: me.id,
      createdAt: _clock(),
      members: <CircleMemberDto>[
        CircleMemberDto(
          profileId: me.id,
          username: me.username,
          displayName: me.displayName,
          role: 'owner',
        ),
      ],
      patient: syncPatient,
    );
    _circles.add(circle);
    return circle;
  }

  @override
  Future<List<CircleDto>> listCircles() async => List<CircleDto>.unmodifiable(
        _circles.map(_withCurrentPatient),
      );

  /// Re-attach the circle's current sync patient (it may have changed
  /// since the [CircleDto] was first cached in [_circles]).
  CircleDto _withCurrentPatient(CircleDto c) =>
      c.copyWith(patient: _sync[c.id]?.patient);

  @override
  Future<CircleInviteDto> createInvite(String circleId) async {
    final bool exists = _circles.any((CircleDto c) => c.id == circleId);
    if (!exists) {
      throw ForumApiException(statusCode: 404, error: 'circle_not_found');
    }
    // 48h TTL, matching the Worker's INVITE_TTL_MS (2026-06-11).
    final DateTime expiresAt = _clock().add(const Duration(hours: 48));
    final String token = _mintId('invite');
    _invites[token] = _FakeInvite(circleId: circleId, expiresAt: expiresAt);
    return CircleInviteDto(
      token: token,
      circleId: circleId,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<CircleDto> joinCircle(String token) async {
    final _FakeInvite? invite = _invites[token];
    if (invite == null) {
      throw ForumApiException(statusCode: 404, error: 'invite_not_found');
    }
    if (!invite.expiresAt.isAfter(_clock())) {
      throw ForumApiException(statusCode: 410, error: 'invite_expired');
    }
    final int idx =
        _circles.indexWhere((CircleDto c) => c.id == invite.circleId);
    if (idx < 0) {
      throw ForumApiException(statusCode: 404, error: 'invite_not_found');
    }
    final ForumProfile me = _resolveMyProfile();
    final CircleDto current = _circles[idx];
    final bool alreadyMember =
        current.members.any((CircleMemberDto m) => m.profileId == me.id);
    if (alreadyMember) {
      // Idempotent for existing members — re-tapping an old link is
      // benign and does not consume anything (mirrors the Worker).
      return _withCurrentPatient(current);
    }
    if (invite.usedByProfileId != null) {
      throw ForumApiException(statusCode: 410, error: 'invite_used');
    }
    invite.usedByProfileId = me.id;
    final CircleDto next = current.copyWith(
      members: <CircleMemberDto>[
        ...current.members,
        CircleMemberDto(
          profileId: me.id,
          username: me.username,
          displayName: me.displayName,
          role: 'member',
        ),
      ],
    );
    _circles[idx] = next;
    return _withCurrentPatient(next);
  }

  // ---- Sync (server-authoritative) ---------------------------------------

  @override
  Future<SyncPullResult> syncPull(String circleId, {int since = 0}) async {
    final _FakeCircleSync? sync = _sync[circleId];
    if (sync == null) {
      return SyncPullResult(cursor: since, patient: null, docs: const <SyncDoc>[]);
    }
    return sync.pull(since);
  }

  @override
  Future<SyncPushResult> syncPush(
    String circleId, {
    SyncPatientWrite? patient,
    required List<SyncDocWrite> docs,
  }) async {
    final _FakeCircleSync sync =
        _sync.putIfAbsent(circleId, () => _FakeCircleSync());
    return sync.push(patient: patient, docs: docs);
  }

  // ---- Document scan blobs -----------------------------------------------

  @override
  Future<String> uploadDocumentBlob({
    required String circleId,
    required String key,
    required List<int> bytes,
    String contentType = 'application/octet-stream',
  }) async {
    final String fullKey = 'documents/$circleId/$key';
    _backend.docBlobs[fullKey] = List<int>.from(bytes);
    return fullKey;
  }

  @override
  Future<List<int>> downloadDocumentBlob({
    required String circleId,
    required String key,
  }) async {
    final List<int>? bytes = _backend.docBlobs['documents/$circleId/$key'];
    if (bytes == null) {
      throw ForumApiException(statusCode: 404, error: 'not_found');
    }
    return List<int>.from(bytes);
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

  /// No-op in demo: there's no server account to delete. Resolves success so
  /// the delete-account flow proceeds to clear local state in demo builds.
  @override
  Future<void> deleteMyProfile() async {}

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

/// In-memory invite record the fake mints from [createInvite] and
/// redeems in [joinCircle] (care-circle connect, 2026-06-06).
class _FakeInvite {
  _FakeInvite({required this.circleId, required this.expiresAt});

  final String circleId;
  final DateTime expiresAt;

  /// Mirrors the Worker's single-use consumption (2026-06-11): set to the
  /// consuming profile id on the first NEW-member join; any later join by
  /// someone else gets `invite_used`.
  String? usedByProfileId;
}

/// Shared circle + sync state for [FakeForumApiClient]
/// (server-authoritative sync). Pass one instance to two clients to
/// model two devices talking to the same backend; omit it and each
/// client gets a private store (the demo / single-device default).
class FakeForumBackend {
  final List<CircleDto> circles = <CircleDto>[];
  // The invite + sync records are internal infra; only [FakeForumApiClient]
  // reaches through these getters, never an external caller.
  // ignore: library_private_types_in_public_api
  final Map<String, _FakeInvite> invites = <String, _FakeInvite>{};
  // ignore: library_private_types_in_public_api
  final Map<String, _FakeCircleSync> sync = <String, _FakeCircleSync>{};

  /// In-memory mirror of the document-scan R2 bucket, keyed by the full
  /// `documents/<circleId>/<key>` storage key so a "two device" test
  /// (one shared backend) round-trips a scan exactly like the real bucket.
  final Map<String, List<int>> docBlobs = <String, List<int>>{};
}

/// Per-circle in-memory mirror of the server's sync store
/// (server-authoritative sync). Holds the monotonic [_rev] counter, the
/// circle-owned patient, and the latest-rev doc per (collection,id), and
/// applies the same LWW rule the real backend does: a write is accepted
/// iff its `client_updated_at` is >= the stored one.
class _FakeCircleSync {
  int _rev = 0;
  SyncPatient? patient;
  final Map<String, SyncDoc> _docs = <String, SyncDoc>{};

  static String _key(String collection, String id) => '$collection|$id';

  SyncPatient upsertPatient({
    required String payload,
    required int clientUpdatedAt,
    bool deleted = false,
  }) {
    final SyncPatient? prior = patient;
    // LWW: reject a stale write but echo the current row back.
    if (prior != null && clientUpdatedAt < prior.clientUpdatedAt) {
      return prior;
    }
    _rev += 1;
    patient = SyncPatient(
      payload: payload,
      clientUpdatedAt: clientUpdatedAt,
      rev: _rev,
      deleted: deleted,
    );
    return patient!;
  }

  SyncPushResult push({
    SyncPatientWrite? patient,
    required List<SyncDocWrite> docs,
  }) {
    if (patient != null) {
      upsertPatient(
        payload: jsonEncode(patient.payload),
        clientUpdatedAt: patient.clientUpdatedAt,
        deleted: patient.deleted,
      );
    }
    final List<({String id, int rev, bool accepted})> applied =
        <({String id, int rev, bool accepted})>[];
    for (final SyncDocWrite d in docs) {
      final String k = _key(d.collection, d.id);
      final SyncDoc? prior = _docs[k];
      if (prior != null && d.clientUpdatedAt < prior.clientUpdatedAt) {
        applied.add((id: d.id, rev: prior.rev, accepted: false));
        continue;
      }
      _rev += 1;
      final SyncDoc next = SyncDoc(
        id: d.id,
        collection: d.collection,
        payload: jsonEncode(d.payload),
        clientUpdatedAt: d.clientUpdatedAt,
        rev: _rev,
        deleted: d.deleted,
      );
      _docs[k] = next;
      applied.add((id: d.id, rev: _rev, accepted: true));
    }
    return SyncPushResult(cursor: _rev, patient: this.patient, applied: applied);
  }

  SyncPullResult pull(int since) {
    final SyncPatient? p =
        (patient != null && patient!.rev > since) ? patient : null;
    final List<SyncDoc> docs = _docs.values
        .where((SyncDoc d) => d.rev > since)
        .toList()
      ..sort((SyncDoc a, SyncDoc b) => a.rev.compareTo(b.rev));
    return SyncPullResult(cursor: _rev, patient: p, docs: docs);
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

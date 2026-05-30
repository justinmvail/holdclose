// ignore_for_file: invalid_annotation_target

import 'package:freezed_annotation/freezed_annotation.dart';

part 'forum.freezed.dart';
part 'forum.g.dart';

/// One link the crisis-flag banner surfaces above a freshly-submitted
/// post or comment (BUILD_SPEC.md §13 / Phase 13.8 + 13.9). Mirrors the
/// Worker's `CrisisHotline` shape — `{label, number, description}` —
/// 1:1 so the response DTO round-trips.
@freezed
abstract class ForumCrisisHotline with _$ForumCrisisHotline {
  const factory ForumCrisisHotline({
    required String label,
    required String number,
    required String description,
  }) = _ForumCrisisHotline;

  factory ForumCrisisHotline.fromJson(Map<String, dynamic> json) =>
      _$ForumCrisisHotlineFromJson(json);
}

/// Crisis-resources payload returned alongside a flagged post / comment
/// (BUILD_SPEC.md §13 / Phase 13.8). The Worker injects this map at the
/// top level of `POST /posts` and `POST /comments` responses whenever
/// the crisis-keyword detector matches; Phase 13.10+ renders a banner
/// from it.
@freezed
abstract class ForumCrisisResources with _$ForumCrisisResources {
  const factory ForumCrisisResources({
    @JsonKey(name: 'crisis_card_url') required String crisisCardUrl,
    required List<ForumCrisisHotline> hotlines,
  }) = _ForumCrisisResources;

  factory ForumCrisisResources.fromJson(Map<String, dynamic> json) =>
      _$ForumCrisisResourcesFromJson(json);
}

/// The signed-in caregiver's own forum profile (BUILD_SPEC.md §13 /
/// Phase 13.4). Returned by `POST /profiles/bootstrap`, `GET
/// /profiles/me`, and `PATCH /profiles/me`. [careblazersUserId] is the
/// foreign key back into the app's auth identity; [role] is `'user'`
/// for everyone except the solo admin.
@freezed
abstract class ForumProfile with _$ForumProfile {
  const factory ForumProfile({
    required String id,
    @JsonKey(name: 'careblazers_user_id') required String careblazersUserId,
    @JsonKey(name: 'display_name') required String displayName,
    @JsonKey(name: 'avatar_url') String? avatarUrl,
    @JsonKey(name: 'joined_at') required DateTime joinedAt,
    required String role,
  }) = _ForumProfile;

  factory ForumProfile.fromJson(Map<String, dynamic> json) =>
      _$ForumProfileFromJson(json);
}

/// A public view of someone else's profile (BUILD_SPEC.md §13 / Phase
/// 13.4). `GET /profiles/:id` strips the auth-identity foreign key and
/// the role flag, replacing them with denormalized post + comment
/// counts the UI can render without a second query.
@freezed
abstract class ForumPublicProfile with _$ForumPublicProfile {
  const factory ForumPublicProfile({
    required String id,
    @JsonKey(name: 'display_name') required String displayName,
    @JsonKey(name: 'avatar_url') String? avatarUrl,
    @JsonKey(name: 'joined_at') required DateTime joinedAt,
    @JsonKey(name: 'post_count') required int postCount,
    @JsonKey(name: 'comment_count') required int commentCount,
  }) = _ForumPublicProfile;

  factory ForumPublicProfile.fromJson(Map<String, dynamic> json) =>
      _$ForumPublicProfileFromJson(json);
}

/// One forum post (BUILD_SPEC.md §13 / Phase 13.5). The `hidden` flag
/// is included on the wire so a moderation hide rendered into the feed
/// surfaces as a stub rather than vanishing — Phase 13.10 collapses
/// hidden rows visually.
@freezed
abstract class ForumPost with _$ForumPost {
  const factory ForumPost({
    required String id,
    @JsonKey(name: 'author_id') required String authorId,
    required String title,
    required String body,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
    @JsonKey(name: 'vote_count') required int voteCount,
    required bool hidden,
    @JsonKey(name: 'crisis_flagged') @Default(false) bool crisisFlagged,
  }) = _ForumPost;

  factory ForumPost.fromJson(Map<String, dynamic> json) =>
      _$ForumPostFromJson(json);
}

/// One forum comment (BUILD_SPEC.md §13 / Phase 13.6). Hidden rows
/// keep their position in the tree but the Worker nulls [authorId] and
/// [body] — the renderer shows a "[removed]" placeholder so the reply
/// chain stitched below the moderated parent remains visible.
@freezed
abstract class ForumComment with _$ForumComment {
  const factory ForumComment({
    required String id,
    @JsonKey(name: 'post_id') required String postId,
    @JsonKey(name: 'parent_comment_id') String? parentCommentId,
    @JsonKey(name: 'author_id') String? authorId,
    String? body,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'vote_count') required int voteCount,
    required int depth,
    required bool hidden,
    @JsonKey(name: 'crisis_flagged') @Default(false) bool crisisFlagged,
  }) = _ForumComment;

  factory ForumComment.fromJson(Map<String, dynamic> json) =>
      _$ForumCommentFromJson(json);
}

/// The result of casting a vote (BUILD_SPEC.md §13 / Phase 13.7). The
/// Worker returns the post / comment's new [voteCount] plus the
/// canonical [value] (-1, 0, or +1) the row now holds — sending value=0
/// against an unvoted target is a no-op and echoes back the existing
/// count.
@freezed
abstract class ForumVoteResponse with _$ForumVoteResponse {
  const factory ForumVoteResponse({
    @JsonKey(name: 'vote_count') required int voteCount,
    required int value,
  }) = _ForumVoteResponse;

  factory ForumVoteResponse.fromJson(Map<String, dynamic> json) =>
      _$ForumVoteResponseFromJson(json);
}

/// A user-or-admin-filed report (BUILD_SPEC.md §13 / Phase 13.8). Both
/// the reporter (after `POST /reports`) and the admin queue (`GET
/// /reports`) see this shape; the admin-only `PATCH /reports/:id`
/// returns the same shape with [status] flipped + [resolvedAt]
/// populated.
@freezed
abstract class ForumReport with _$ForumReport {
  const factory ForumReport({
    required String id,
    @JsonKey(name: 'target_kind') required String targetKind,
    @JsonKey(name: 'target_id') required String targetId,
    @JsonKey(name: 'reporter_id') required String reporterId,
    required String reason,
    required String status,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'resolved_at') DateTime? resolvedAt,
  }) = _ForumReport;

  factory ForumReport.fromJson(Map<String, dynamic> json) =>
      _$ForumReportFromJson(json);
}

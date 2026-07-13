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
    // The caregiver's chosen `@handle` (care-circle connect, 2026-06-06).
    // Null until they pick one via `PATCH /profiles/me {username}`; the
    // Worker also returns null for legacy rows that predate the column.
    String? username,
  }) = _ForumProfile;

  factory ForumProfile.fromJson(Map<String, dynamic> json) =>
      _$ForumProfileFromJson(json);
}

/// The name a freshly-minted care circle takes from its owner [profile]
/// (username propagation, 2026-06-07). Username is the canonical public
/// identity, so a circle reads as `@handle's care circle` when the owner
/// has set a username; otherwise it falls back to their display name
/// (`Name's care circle`). Shared by both circle-creation entry points
/// (Add-by-username and Show-my-QR) so a circle is named the same way
/// regardless of how it was bootstrapped.
String circleNameForOwner(ForumProfile profile) {
  final String? username = profile.username;
  if (username != null && username.isNotEmpty) {
    return "@$username's care circle";
  }
  return "${profile.displayName}'s care circle";
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
    // joined_at + the denormalized counts are absent from the lean
    // `GET /profiles/by-username/:username` lookup (which returns only
    // {id, username, display_name, avatar_url}); default them so that
    // response decodes into the same DTO as the full `GET /profiles/:id`.
    @JsonKey(name: 'joined_at') DateTime? joinedAt,
    @JsonKey(name: 'post_count') @Default(0) int postCount,
    @JsonKey(name: 'comment_count') @Default(0) int commentCount,
    // The caregiver's `@handle` (care-circle connect, 2026-06-06).
    String? username,
  }) = _ForumPublicProfile;

  factory ForumPublicProfile.fromJson(Map<String, dynamic> json) =>
      _$ForumPublicProfileFromJson(json);
}

/// One forum post (BUILD_SPEC.md §13 / Phase 13.5). The `hidden` flag
/// is included on the wire so a moderation hide rendered into the feed
/// surfaces as a stub rather than vanishing — Phase 13.10 collapses
/// hidden rows visually.
///
/// [commentCount] is a denormalized post-row counter the feed renders
/// alongside [voteCount] in the per-post card (Phase 13.10). Defaults
/// to 0 so existing fixtures + the pre-Phase-13.10 wire shape still
/// parse cleanly — a Worker that doesn't yet emit the field collapses
/// to "no comments yet" rather than failing decode.
@freezed
abstract class ForumPost with _$ForumPost {
  const factory ForumPost({
    required String id,
    @JsonKey(name: 'author_id') required String authorId,
    // The post author's chosen `@handle` and display name, denormalized
    // onto the wire (username propagation, 2026-06-07) so the feed/detail
    // renders the real name without a per-author profile fetch. Both are
    // null for a row whose author profile was deleted, or on a legacy
    // Worker that predates these fields.
    @JsonKey(name: 'author_username') String? authorUsername,
    @JsonKey(name: 'author_display_name') String? authorDisplayName,
    /// The author's profile photo, served from the backend's media origin.
    /// Null when they haven't set one — the UI falls back to the initial.
    @JsonKey(name: 'author_avatar_url') String? authorAvatarUrl,
    required String title,
    required String body,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
    @JsonKey(name: 'vote_count') required int voteCount,
    required bool hidden,
    @JsonKey(name: 'crisis_flagged') @Default(false) bool crisisFlagged,
    @JsonKey(name: 'comment_count') @Default(0) int commentCount,
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
    // The comment author's `@handle` + display name (username propagation,
    // 2026-06-07). Null on a moderated/hidden row (the Worker strips the
    // author there) or a legacy Worker that predates these fields.
    @JsonKey(name: 'author_username') String? authorUsername,
    @JsonKey(name: 'author_display_name') String? authorDisplayName,
    /// The author's profile photo, served from the backend's media origin.
    /// Null when they haven't set one — the UI falls back to the initial.
    @JsonKey(name: 'author_avatar_url') String? authorAvatarUrl,
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

/// One member of a care circle (care-circle connect, 2026-06-06).
/// Mirrors the Worker's `members[]` element on every circle response —
/// `{profile_id, username, display_name, role}`. [username] is null
/// until the member picks an `@handle`; [role] is `owner` for the
/// circle creator and `member` for everyone who joined via an invite.
@freezed
abstract class CircleMemberDto with _$CircleMemberDto {
  const factory CircleMemberDto({
    @JsonKey(name: 'profile_id') required String profileId,
    String? username,
    @JsonKey(name: 'display_name') required String displayName,
    required String role,
  }) = _CircleMemberDto;

  factory CircleMemberDto.fromJson(Map<String, dynamic> json) =>
      _$CircleMemberDtoFromJson(json);
}

/// The circle-owned loved one as it lives on the sync backend
/// (server-authoritative sync). Carried on every circle response so a
/// joiner adopts the shared loved one in the same round-trip that joins
/// them. [payload] is the [Patient]'s `toJson` shape encoded as a JSON
/// **string** on the wire; decode with `jsonDecode` then
/// `Patient.fromJson`. [rev] is the server's monotonic revision; [deleted]
/// is the tombstone flag.
@freezed
abstract class SyncPatient with _$SyncPatient {
  const factory SyncPatient({
    required String payload,
    @JsonKey(name: 'client_updated_at') required int clientUpdatedAt,
    required int rev,
    @Default(false) bool deleted,
  }) = _SyncPatient;

  factory SyncPatient.fromJson(Map<String, dynamic> json) =>
      _$SyncPatientFromJson(json);
}

/// One synced document — a circle-scoped row in some [collection]
/// (`medication`, `dose_window`, …) (server-authoritative sync).
/// [payload] is the model's `toJson` shape encoded as a JSON **string**
/// on the wire. A pulled doc with [deleted] true is a tombstone the
/// apply dispatcher routes to the matching local delete.
@freezed
abstract class SyncDoc with _$SyncDoc {
  const factory SyncDoc({
    required String id,
    required String collection,
    required String payload,
    @JsonKey(name: 'client_updated_at') required int clientUpdatedAt,
    required int rev,
    @Default(false) bool deleted,
  }) = _SyncDoc;

  factory SyncDoc.fromJson(Map<String, dynamic> json) =>
      _$SyncDocFromJson(json);
}

/// A care circle (care-circle connect, 2026-06-06). Returned by
/// `POST /circles`, `GET /circles`, and `POST /circles/join`. Carries
/// the denormalized [members] roster so the People surface renders the
/// circle without a second round-trip, and (server-authoritative sync)
/// the circle-owned [patient] so a joiner adopts the shared loved one
/// without a separate fetch. [patient] is null for a circle that has no
/// loved one on file yet.
@freezed
abstract class CircleDto with _$CircleDto {
  const factory CircleDto({
    required String id,
    required String name,
    @JsonKey(name: 'owner_profile_id') required String ownerProfileId,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @Default(<CircleMemberDto>[]) List<CircleMemberDto> members,
    SyncPatient? patient,
  }) = _CircleDto;

  factory CircleDto.fromJson(Map<String, dynamic> json) =>
      _$CircleDtoFromJson(json);
}

/// A circle invite (care-circle connect, 2026-06-06). Returned by
/// `POST /circles/:id/invites`. [token] is the opaque join code the
/// QR encodes; a co-caregiver joins by POSTing it back to
/// `POST /circles/join` before [expiresAt].
@freezed
abstract class CircleInviteDto with _$CircleInviteDto {
  const factory CircleInviteDto({
    required String token,
    @JsonKey(name: 'circle_id') required String circleId,
    @JsonKey(name: 'expires_at') required DateTime expiresAt,
  }) = _CircleInviteDto;

  factory CircleInviteDto.fromJson(Map<String, dynamic> json) =>
      _$CircleInviteDtoFromJson(json);
}

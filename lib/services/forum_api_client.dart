import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/forum.dart';
import '../providers/forum_jwt_provider.dart';
import '../providers/settings_provider.dart';
import 'fake_forum_api_client.dart';

part 'forum_api_client.g.dart';

/// Build-time injection point for the deployed Worker URL
/// (BUILD_SPEC.md §13 / Phase 13.9). Operator passes
/// `--dart-define=FORUM_API_URL=https://forum-api.workers.dev` for
/// prod or `--dart-define=FORUM_API_URL=http://127.0.0.1:8787` for a
/// `wrangler dev` loop. Defaults to the Cloudflare-style hostname so
/// the no-define case still produces a recognisably-wrong URL rather
/// than silently hitting localhost.
// Empty default = "no backend configured" → the app uses the fake forum
// client and stays fully local (tests, demo builds). A real URL is only
// present when an alpha/prod build bakes in
// `--dart-define=FORUM_API_URL=...`; that's what flips the
// `forumApiClient` provider to the live client (so testers never have to
// find the "Use demo forum" toggle).
const String _compileTimeForumApiUrl = String.fromEnvironment(
  'FORUM_API_URL',
);

/// True only when a real backend URL was baked into the build (an
/// alpha/prod `--dart-define=FORUM_API_URL=...`). Callers that hit the
/// live backend (e.g. the synced circle-members section) gate on this so
/// tests + local-only/demo builds never instantiate the real auth path.
final bool forumBackendConfigured = _compileTimeForumApiUrl.trim().isNotEmpty;

/// All Hono routes mount under this prefix (BUILD_SPEC.md §13 / Phase
/// 13.3 — `app.route('/api/v1', api)`). Centralized so a future v2
/// flip only touches one line.
const String forumApiVersionPrefix = '/api/v1';

/// Exception thrown by [ForumApiClient] on non-2xx responses. Carries
/// the Worker's JSON `{error: '...'}` payload (if any) plus the
/// HTTP status so callers can branch on auth failure (401),
/// not-found (404), or generic transport (anything else).
///
/// [tokenExpired] is true when the Worker's `auth.ts` middleware
/// emits the `Token-Expired: true` response header alongside its 401.
/// The Phase 13.10 forum surfaces use that signal to invalidate the
/// minter's cache + retry once before bouncing to the sign-in screen.
class ForumApiException implements Exception {
  ForumApiException({
    required this.statusCode,
    required this.error,
    this.tokenExpired = false,
    this.cause,
  });

  final int statusCode;
  final String error;
  final bool tokenExpired;
  final Object? cause;

  @override
  String toString() =>
      'ForumApiException($statusCode, $error${tokenExpired ? ', token_expired' : ''})';
}

/// Decoded `POST /api/v1/auth/google` success body (the Google sign-in
/// bootstrap). The backend verifies the Google ID token, provisions /
/// finds the account, and returns the stable spine identity PLUS the
/// SERVER-minted session JWT ([token], expiring at [tokenExpiresAt]
/// epoch seconds) that authenticates every subsequent call. [username]
/// is null until the caregiver claims a `@handle`. [token] is nullable
/// only for tolerance of an older backend during rollout.
class GoogleAuthResult {
  const GoogleAuthResult({
    required this.userId,
    required this.email,
    required this.name,
    this.username,
    this.token,
    this.tokenExpiresAt,
  });

  final String userId;
  final String email;
  final String name;
  final String? username;
  final String? token;
  final int? tokenExpiresAt;

  factory GoogleAuthResult.fromJson(Map<String, Object?> json) =>
      GoogleAuthResult(
        userId: json['user_id'] as String? ?? '',
        email: json['email'] as String? ?? '',
        name: json['name'] as String? ?? '',
        username: json['username'] as String?,
        token: json['token'] as String?,
        tokenExpiresAt: (json['token_expires_at'] as num?)?.toInt(),
      );
}

/// Thrown by [ForumApiClient.verifyGoogleIdToken] when the backend
/// rejects the bootstrap. [code] mirrors the Worker's `{error}` payload
/// (`invalid_token` on 401, `missing_id_token` on 400, or a synthetic
/// transport code) so the sign-in screen can branch / log without
/// reaching for the raw [ForumApiException].
class GoogleAuthException implements Exception {
  const GoogleAuthException({required this.statusCode, required this.code});

  final int statusCode;
  final String code;

  @override
  String toString() => 'GoogleAuthException($statusCode, $code)';
}

/// Combined response from `POST /posts` (BUILD_SPEC.md §13 / Phase
/// 13.5 + 13.8). The Worker injects a top-level `crisis_resources`
/// field on flagged content; the field is absent on benign posts.
class ForumCreatePostResponse {
  const ForumCreatePostResponse({
    required this.post,
    this.crisisResources,
  });

  final ForumPost post;
  final ForumCrisisResources? crisisResources;
}

/// Same `{row + optional crisis_resources}` envelope as
/// [ForumCreatePostResponse], for `POST /posts/:id/comments`.
class ForumCreateCommentResponse {
  const ForumCreateCommentResponse({
    required this.comment,
    this.crisisResources,
  });

  final ForumComment comment;
  final ForumCrisisResources? crisisResources;
}

/// Returned by `PATCH /reports/:id` (BUILD_SPEC.md §13 / Phase 13.8).
/// Echoes the report row with [action] (what the admin chose) and
/// [bannedUserId] (the affected author id for `ban_user`, null
/// otherwise).
class ForumReportReviewResponse {
  const ForumReportReviewResponse({
    required this.report,
    required this.action,
    this.bannedUserId,
  });

  final ForumReport report;
  final String action;
  final String? bannedUserId;
}

/// Sort key for the `GET /posts` feed (BUILD_SPEC.md §13 / Phase 13.5).
enum ForumPostSort {
  hot,
  newest,
  top;

  /// Wire encoding the Worker accepts on `?sort=`. `newest` is renamed
  /// for the wire because `new` collides with the Dart keyword.
  String get queryValue => switch (this) {
        ForumPostSort.hot => 'hot',
        ForumPostSort.newest => 'new',
        ForumPostSort.top => 'top',
      };
}

/// Sort key for `GET /posts/:postId/comments` (Phase 13.6).
enum ForumCommentSort {
  top,
  newest;

  String get queryValue => switch (this) {
        ForumCommentSort.top => 'top',
        ForumCommentSort.newest => 'new',
      };
}

/// Vote target — wire values mirror the Worker's
/// `VOTE_TARGET_POST` / `VOTE_TARGET_COMMENT` constants.
enum ForumVoteTarget {
  post,
  comment;

  String get queryValue => switch (this) {
        ForumVoteTarget.post => 'post',
        ForumVoteTarget.comment => 'comment',
      };
}

/// Admin review action for `PATCH /reports/:id` (Phase 13.8).
enum ForumReportAction {
  noAction,
  hideTarget,
  banUser;

  String get queryValue => switch (this) {
        ForumReportAction.noAction => 'no_action',
        ForumReportAction.hideTarget => 'hide_target',
        ForumReportAction.banUser => 'ban_user',
      };
}

// ---------------------------------------------------------------------------
// Sync write + result DTOs (server-authoritative sync)
//
// The pull/return shapes ([SyncDoc] / [SyncPatient] in models/forum.dart)
// carry [payload] as a JSON *string* — that's the wire shape. The *write*
// DTOs below take [payload] as a decoded `Map` so call sites enqueue a
// model's `toJson()` directly; [syncPush] re-encodes to a string at the
// boundary. The result DTOs ([SyncPullResult] / [SyncPushResult]) are
// plain (non-freezed) holders because they never round-trip back over the
// wire — they're the decoded shape callers consume in-process.
// ---------------------------------------------------------------------------

/// One document a client is pushing up (server-authoritative sync).
/// [payload] is the model's `toJson` map; [syncPush] encodes it to the
/// wire's JSON string. [deleted] marks a tombstone the server accepts
/// under the same LWW rule as a live write.
class SyncDocWrite {
  const SyncDocWrite({
    required this.id,
    required this.collection,
    required this.payload,
    required this.clientUpdatedAt,
    this.deleted = false,
  });

  final String id;
  final String collection;
  final Map<String, dynamic> payload;
  final int clientUpdatedAt;
  final bool deleted;

  Map<String, Object?> toWire() => <String, Object?>{
        'id': id,
        'collection': collection,
        'payload': jsonEncode(payload),
        'client_updated_at': clientUpdatedAt,
        'deleted': deleted,
      };
}

/// The circle-owned loved one a client is pushing up
/// (server-authoritative sync). [payload] is the [Patient]'s `toJson`
/// map; [syncPush] encodes it to the wire's JSON string.
class SyncPatientWrite {
  const SyncPatientWrite({
    required this.payload,
    required this.clientUpdatedAt,
    this.deleted = false,
  });

  final Map<String, dynamic> payload;
  final int clientUpdatedAt;
  final bool deleted;

  Map<String, Object?> toWire() => <String, Object?>{
        'payload': jsonEncode(payload),
        'client_updated_at': clientUpdatedAt,
        'deleted': deleted,
      };
}

/// Decoded `GET /sync/:circleId` response (server-authoritative sync).
/// [cursor] is the server rev the caller persists + passes back as
/// `since` next pull; [patient] / [docs] are present only for rows whose
/// rev exceeds the requested `since`.
class SyncPullResult {
  const SyncPullResult({
    required this.cursor,
    required this.patient,
    required this.docs,
  });

  final int cursor;
  final SyncPatient? patient;
  final List<SyncDoc> docs;
}

/// Decoded `POST /sync/:circleId` response (server-authoritative sync).
/// [applied] echoes each pushed doc's id with the server-assigned [rev]
/// and whether the LWW check [accepted] it.
class SyncPushResult {
  const SyncPushResult({
    required this.cursor,
    required this.patient,
    required this.applied,
  });

  final int cursor;
  final SyncPatient? patient;
  final List<({String id, int rev, bool accepted})> applied;
}

/// Async producer of a bearer token for the Authorization header.
/// Production wires this to `ForumSessionManager.currentToken` (the
/// SERVER-minted session token); tests inject a constant closure so the
/// API client tests stay independent of the session machinery (which
/// has its own coverage in `test/providers/forum_jwt_provider_test.dart`).
typedef ForumTokenLoader = Future<String> Function();

/// Invoked when the Worker rejects a call with 401 + `Token-Expired:
/// true`. Production wires this to `ForumSessionManager.recoverFromExpiry`
/// (drop the dead token, silently re-exchange). Returns true when a
/// usable token now exists — the client then retries the request ONCE.
typedef ForumTokenExpiredRecovery = Future<bool> Function();

/// Dio-backed thin wrapper around the Cloudflare Worker forum API
/// (BUILD_SPEC.md §13 / Phase 13.9). One method per Worker route.
///
/// Read endpoints (`GET /posts`, `GET /posts/:id`, `GET
/// /posts/:postId/comments`) skip the Authorization header to match
/// the Worker's anonymous-read posture. Every other endpoint pulls the
/// server-minted session JWT via [tokenLoader] (wired to
/// `ForumSessionManager.currentToken` in the riverpod wiring).
///
/// On non-2xx the client raises [ForumApiException] with the Worker's
/// `{error: '...'}` payload extracted; callers should NOT need to
/// touch [Dio]/[DioException] directly.
class ForumApiClient {
  ForumApiClient({
    required ForumTokenLoader tokenLoader,
    ForumTokenExpiredRecovery? onTokenExpired,
    Dio? dio,
    String baseUrl = _compileTimeForumApiUrl,
  })  : _tokenLoader = tokenLoader,
        _onTokenExpired = onTokenExpired,
        // A bare Dio() has NO timeouts — one black-holed request (the
        // backend is a Funnel to a laptop) would otherwise wedge the
        // sync engine's in-flight slot until app restart. Send/receive
        // are generous enough for the 8 MB document-blob ceiling on a
        // slow uplink, but finite.
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 120),
              receiveTimeout: const Duration(seconds: 60),
            )),
        _baseUrl = _trimTrailingSlash(baseUrl);

  final ForumTokenLoader _tokenLoader;
  final ForumTokenExpiredRecovery? _onTokenExpired;
  final Dio _dio;
  final String _baseUrl;

  /// Exposed for tests + diagnostics. The trailing slash is stripped
  /// at construction so callers can concat `$baseUrl/api/v1/...`
  /// without worrying about double-slashes.
  String get baseUrl => _baseUrl;

  /// The base + version prefix the API methods build paths off of.
  String get _apiBase => '$_baseUrl$forumApiVersionPrefix';

  // -------- Auth bootstrap (pre-auth Google sign-in) ----------------------

  /// Exchange a Google ID token for the backend's stable account spine
  /// (BUILD_SPEC.md §13). This endpoint is UNAUTHENTICATED — it is the
  /// bootstrap that *establishes* the identity the forum JWT is later
  /// minted from, so it must NOT attach a Bearer token (sending the
  /// to-be-issued `sub` would be circular). Posts
  /// `{id_token: <google id token>}`; returns the verified
  /// `{user_id, email, name, username}`.
  ///
  /// Throws [GoogleAuthException] on the documented failures — 401
  /// `invalid_token` (Google rejected / audience mismatch) or 400
  /// `missing_id_token` — so the sign-in screen surfaces a friendly
  /// message instead of a raw transport error.
  Future<GoogleAuthResult> verifyGoogleIdToken(String idToken) async {
    try {
      final Response<dynamic> r = await _post(
        '$_apiBase/auth/google',
        data: <String, Object?>{'id_token': idToken},
        anonymous: true,
      );
      return GoogleAuthResult.fromJson(_asJsonObject(r));
    } on ForumApiException catch (e) {
      throw GoogleAuthException(statusCode: e.statusCode, code: e.error);
    }
  }

  // -------- Profiles ------------------------------------------------------

  Future<ForumProfile> bootstrapProfile() async {
    final Response<dynamic> r = await _post(
      '$_apiBase/profiles/bootstrap',
      data: const <String, Object?>{},
    );
    return ForumProfile.fromJson(_asJsonObject(r));
  }

  Future<ForumProfile> getMyProfile() async {
    final Response<dynamic> r = await _get('$_apiBase/profiles/me');
    return ForumProfile.fromJson(_asJsonObject(r));
  }

  Future<ForumProfile> updateMyProfile({
    String? displayName,
    String? avatarUrl,
    String? username,
  }) async {
    final Map<String, Object?> body = <String, Object?>{};
    if (displayName != null) body['display_name'] = displayName;
    if (avatarUrl != null) body['avatar_url'] = avatarUrl;
    if (username != null) body['username'] = username;
    final Response<dynamic> r = await _patch(
      '$_apiBase/profiles/me',
      data: body,
    );
    return ForumProfile.fromJson(_asJsonObject(r));
  }

  Future<ForumPublicProfile> getPublicProfile(String profileId) async {
    final Response<dynamic> r = await _get(
      '$_apiBase/profiles/$profileId',
    );
    return ForumPublicProfile.fromJson(_asJsonObject(r));
  }

  // -------- Username + circles (care-circle connect, 2026-06-06) ----------

  /// Check whether [handle] is a syntactically-valid + unclaimed
  /// `@username`. The Worker returns `{valid, available}` — `valid`
  /// reflects the `^[a-z0-9_]{3,20}$` rule, `available` whether someone
  /// already holds it. Drives the live availability check on the
  /// username-onboarding screen.
  Future<({bool valid, bool available})> usernameAvailable(
    String handle,
  ) async {
    final Response<dynamic> r = await _get(
      '$_apiBase/profiles/username-available',
      query: <String, Object?>{'u': handle},
    );
    final Map<String, Object?> body = _asJsonObject(r);
    return (
      valid: body['valid'] == true,
      available: body['available'] == true,
    );
  }

  /// Resolve another caregiver's lean public profile by their
  /// `@username` (`{id, username, display_name, avatar_url}`). Raises a
  /// 404 [ForumApiException] with `profile_not_found` when no one holds
  /// the handle.
  Future<ForumPublicProfile> getProfileByUsername(String username) async {
    final Response<dynamic> r = await _get(
      '$_apiBase/profiles/by-username/$username',
    );
    return ForumPublicProfile.fromJson(_asJsonObject(r));
  }

  /// Create a new care circle the caller owns. [name] is 1..60 chars.
  /// When [patient] is supplied the circle is created owning that loved
  /// one (server-authoritative sync) — the response carries it back as
  /// [CircleDto.patient] with a server-assigned rev.
  Future<CircleDto> createCircle(
    String name, {
    SyncPatientWrite? patient,
  }) async {
    final Map<String, Object?> body = <String, Object?>{'name': name};
    if (patient != null) {
      body['patient'] = <String, Object?>{
        'payload': jsonEncode(patient.payload),
        'client_updated_at': patient.clientUpdatedAt,
      };
    }
    final Response<dynamic> r = await _post(
      '$_apiBase/circles',
      data: body,
    );
    return CircleDto.fromJson(_asJsonObject(r));
  }

  /// Every circle the caller belongs to, each with its [members] roster.
  Future<List<CircleDto>> listCircles() async {
    final Response<dynamic> r = await _get('$_apiBase/circles');
    final Map<String, Object?> body = _asJsonObject(r);
    final List<dynamic> rows =
        (body['circles'] as List<dynamic>?) ?? const <dynamic>[];
    return rows
        .map((dynamic e) => CircleDto.fromJson(_asObject(e)))
        .toList(growable: false);
  }

  /// Mint a single-use, time-boxed join invite for [circleId]. The
  /// returned [CircleInviteDto.token] is what the QR encodes.
  Future<CircleInviteDto> createInvite(String circleId) async {
    final Response<dynamic> r = await _post(
      '$_apiBase/circles/$circleId/invites',
      data: const <String, Object?>{},
    );
    return CircleInviteDto.fromJson(_asJsonObject(r));
  }

  /// Join a circle by redeeming an invite [token] (scanned from a QR).
  /// Raises `invite_not_found` (404) or `invite_expired` (410) as a
  /// [ForumApiException] so the scanner can show a friendly message.
  Future<CircleDto> joinCircle(String token) async {
    final Response<dynamic> r = await _post(
      '$_apiBase/circles/join',
      data: <String, Object?>{'token': token},
    );
    return CircleDto.fromJson(_asJsonObject(r));
  }

  // -------- Sync (server-authoritative) -----------------------------------

  /// Pull every patient/doc change in [circleId] whose rev exceeds
  /// [since] (server-authoritative sync). The returned [SyncPullResult.cursor]
  /// is what the caller persists + passes back as [since] next time.
  /// Docs include tombstones (`deleted: true`).
  Future<SyncPullResult> syncPull(String circleId, {int since = 0}) async {
    final Response<dynamic> r = await _get(
      '$_apiBase/sync/$circleId',
      query: <String, Object?>{'since': since},
    );
    final Map<String, Object?> body = _asJsonObject(r);
    return SyncPullResult(
      cursor: (body['cursor'] as num?)?.toInt() ?? since,
      patient: _parseSyncPatient(body['patient']),
      docs: _parseSyncDocs(body['docs']),
    );
  }

  /// Push local [docs] (and optionally the [patient]) up to [circleId]
  /// (server-authoritative sync). The server applies LWW — it accepts a
  /// row iff the incoming `client_updated_at` is >= the stored one — and
  /// echoes the outcome per id in [SyncPushResult.applied].
  Future<SyncPushResult> syncPush(
    String circleId, {
    SyncPatientWrite? patient,
    required List<SyncDocWrite> docs,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'docs': docs.map((SyncDocWrite d) => d.toWire()).toList(),
    };
    if (patient != null) {
      body['patient'] = patient.toWire();
    }
    final Response<dynamic> r = await _post(
      '$_apiBase/sync/$circleId',
      data: body,
    );
    final Map<String, Object?> resBody = _asJsonObject(r);
    final List<dynamic> appliedRows =
        (resBody['applied'] as List<dynamic>?) ?? const <dynamic>[];
    return SyncPushResult(
      cursor: (resBody['cursor'] as num?)?.toInt() ?? 0,
      patient: _parseSyncPatient(resBody['patient']),
      applied: appliedRows.map((dynamic e) {
        final Map<String, Object?> m = _asObject(e);
        return (
          id: m['id'] as String? ?? '',
          rev: (m['rev'] as num?)?.toInt() ?? 0,
          accepted: m['accepted'] == true,
        );
      }).toList(growable: false),
    );
  }

  static SyncPatient? _parseSyncPatient(dynamic value) {
    if (value is Map) {
      return SyncPatient.fromJson(Map<String, dynamic>.from(value));
    }
    return null;
  }

  static List<SyncDoc> _parseSyncDocs(dynamic value) {
    if (value is! List) return const <SyncDoc>[];
    return value
        .whereType<Map>()
        .map((Map e) => SyncDoc.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  // -------- Document scan blobs (R2) --------------------------------------

  /// Upload a document-scan image's raw [bytes] to R2 under [circleId]/[key]
  /// (so the scan survives a reinstall + syncs across the circle). Returns
  /// the full storage key the caller persists on the document row. [key] is
  /// the per-document object name (the circle prefix is added server-side).
  /// Best-effort callers (the [DocumentBlobService]) catch
  /// [ForumApiException] and keep the local path working.
  Future<String> uploadDocumentBlob({
    required String circleId,
    required String key,
    required List<int> bytes,
    String contentType = 'application/octet-stream',
  }) async {
    final String token = await _tokenLoader();
    try {
      final Response<dynamic> r = await _dio
          .request<dynamic>(
            '$_apiBase/documents/blob/$circleId/$key',
            data: Stream<List<int>>.fromIterable(<List<int>>[bytes]),
            options: Options(
              method: 'PUT',
              headers: <String, Object>{
                'Authorization': 'Bearer $token',
                Headers.contentLengthHeader: bytes.length,
              },
              contentType: contentType,
              validateStatus: (int? _) => true,
            ),
          )
          .then(_throwIfError);
      final Map<String, Object?> body = _asJsonObject(r);
      return body['key'] as String? ?? '';
    } on DioException catch (e) {
      throw ForumApiException(
        statusCode: e.response?.statusCode ?? 0,
        error: e.message ?? 'transport_error',
        cause: e,
      );
    }
  }

  /// Download a document-scan blob's raw bytes from R2 under [circleId]/[key].
  /// [key] is the per-document object name (the same value passed to
  /// [uploadDocumentBlob], NOT the full returned storage key). Raises a 404
  /// [ForumApiException] when the object is absent.
  Future<List<int>> downloadDocumentBlob({
    required String circleId,
    required String key,
  }) async {
    final String token = await _tokenLoader();
    try {
      final Response<List<int>> r = await _dio
          .request<List<int>>(
            '$_apiBase/documents/blob/$circleId/$key',
            options: Options(
              method: 'GET',
              headers: <String, Object>{'Authorization': 'Bearer $token'},
              responseType: ResponseType.bytes,
              validateStatus: (int? _) => true,
            ),
          )
          .then((Response<List<int>> resp) {
        final int status = resp.statusCode ?? 0;
        if (status >= 200 && status < 300) return resp;
        throw ForumApiException(
          statusCode: status,
          error: 'http_$status',
        );
      });
      return r.data ?? const <int>[];
    } on DioException catch (e) {
      throw ForumApiException(
        statusCode: e.response?.statusCode ?? 0,
        error: e.message ?? 'transport_error',
        cause: e,
      );
    }
  }

  // -------- Posts ---------------------------------------------------------

  /// Paginated feed. [before] is the last id of the previous page;
  /// omit on the first call. [limit] caps at 50 server-side; values
  /// above 50 quietly clamp.
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async {
    final Map<String, Object?> query = <String, Object?>{
      'sort': sort.queryValue,
    };
    if (before != null) query['before'] = before;
    if (limit != null) query['limit'] = limit;
    final Response<dynamic> r = await _get(
      '$_apiBase/posts',
      query: query,
      anonymous: true,
    );
    final Map<String, Object?> body = _asJsonObject(r);
    final List<dynamic> rows = (body['posts'] as List<dynamic>?) ??
        const <dynamic>[];
    return rows
        .map((dynamic e) => ForumPost.fromJson(_asObject(e)))
        .toList(growable: false);
  }

  Future<ForumPost> getPost(String postId) async {
    final Response<dynamic> r = await _get(
      '$_apiBase/posts/$postId',
      anonymous: true,
    );
    return ForumPost.fromJson(_asJsonObject(r));
  }

  Future<ForumCreatePostResponse> createPost({
    required String title,
    required String body,
  }) async {
    final Response<dynamic> r = await _post(
      '$_apiBase/posts',
      data: <String, Object?>{'title': title, 'body': body},
    );
    return _parseCreatePostResponse(_asJsonObject(r));
  }

  Future<ForumPost> updatePost({
    required String postId,
    required String body,
  }) async {
    final Response<dynamic> r = await _patch(
      '$_apiBase/posts/$postId',
      data: <String, Object?>{'body': body},
    );
    return ForumPost.fromJson(_asJsonObject(r));
  }

  Future<void> deletePost(String postId) async {
    await _delete('$_apiBase/posts/$postId');
  }

  // -------- Comments ------------------------------------------------------

  Future<List<ForumComment>> listComments({
    required String postId,
    ForumCommentSort sort = ForumCommentSort.top,
  }) async {
    final Response<dynamic> r = await _get(
      '$_apiBase/posts/$postId/comments',
      query: <String, Object?>{'sort': sort.queryValue},
      anonymous: true,
    );
    final Map<String, Object?> body = _asJsonObject(r);
    final List<dynamic> rows = (body['comments'] as List<dynamic>?) ??
        const <dynamic>[];
    return rows
        .map((dynamic e) => ForumComment.fromJson(_asObject(e)))
        .toList(growable: false);
  }

  Future<ForumCreateCommentResponse> createComment({
    required String postId,
    required String body,
    String? parentCommentId,
  }) async {
    final Map<String, Object?> data = <String, Object?>{'body': body};
    if (parentCommentId != null) {
      data['parent_comment_id'] = parentCommentId;
    }
    final Response<dynamic> r = await _post(
      '$_apiBase/posts/$postId/comments',
      data: data,
    );
    return _parseCreateCommentResponse(_asJsonObject(r));
  }

  Future<void> deleteComment(String commentId) async {
    await _delete('$_apiBase/comments/$commentId');
  }

  // -------- Votes ---------------------------------------------------------

  /// Cast a vote. [value] must be -1, 0, or +1; 0 withdraws an
  /// existing vote (the Worker rejects other values with `invalid_value`).
  Future<ForumVoteResponse> castVote({
    required ForumVoteTarget targetKind,
    required String targetId,
    required int value,
  }) async {
    assert(
      value == -1 || value == 0 || value == 1,
      'vote value must be one of -1, 0, +1 (got $value)',
    );
    final Response<dynamic> r = await _post(
      '$_apiBase/votes',
      data: <String, Object?>{
        'target_kind': targetKind.queryValue,
        'target_id': targetId,
        'value': value,
      },
    );
    return ForumVoteResponse.fromJson(_asJsonObject(r));
  }

  // -------- Reports -------------------------------------------------------

  Future<ForumReport> submitReport({
    required ForumVoteTarget targetKind,
    required String targetId,
    required String reason,
  }) async {
    final Response<dynamic> r = await _post(
      '$_apiBase/reports',
      data: <String, Object?>{
        'target_kind': targetKind.queryValue,
        'target_id': targetId,
        'reason': reason,
      },
    );
    return ForumReport.fromJson(_asJsonObject(r));
  }

  /// Admin-only. Non-admin callers get a 403 surfaced as
  /// [ForumApiException]. [status] defaults to `pending` (the Worker's
  /// own default).
  Future<List<ForumReport>> listReports({String? status}) async {
    final Map<String, Object?> query = <String, Object?>{};
    if (status != null) query['status'] = status;
    final Response<dynamic> r = await _get(
      '$_apiBase/reports',
      query: query,
    );
    final Map<String, Object?> body = _asJsonObject(r);
    final List<dynamic> rows = (body['reports'] as List<dynamic>?) ??
        const <dynamic>[];
    return rows
        .map((dynamic e) => ForumReport.fromJson(_asObject(e)))
        .toList(growable: false);
  }

  /// Admin-only. [action] selects the side effect: no-op, hide the
  /// target row, or hide + ban the author.
  Future<ForumReportReviewResponse> reviewReport({
    required String reportId,
    required ForumReportAction action,
  }) async {
    final Response<dynamic> r = await _patch(
      '$_apiBase/reports/$reportId',
      data: <String, Object?>{'action': action.queryValue},
    );
    final Map<String, Object?> body = _asJsonObject(r);
    final Map<String, Object?> reportJson = Map<String, Object?>.of(body)
      ..remove('action')
      ..remove('banned_user_id');
    return ForumReportReviewResponse(
      report: ForumReport.fromJson(reportJson),
      action: body['action'] as String? ?? action.queryValue,
      bannedUserId: body['banned_user_id'] as String?,
    );
  }

  // -------- Internals -----------------------------------------------------

  Future<Response<dynamic>> _get(
    String url, {
    Map<String, Object?>? query,
    bool anonymous = false,
  }) =>
      _send(
        method: 'GET',
        url: url,
        query: query,
        anonymous: anonymous,
      );

  Future<Response<dynamic>> _post(
    String url, {
    required Object data,
    bool anonymous = false,
  }) =>
      _send(method: 'POST', url: url, data: data, anonymous: anonymous);

  Future<Response<dynamic>> _patch(
    String url, {
    required Object data,
  }) =>
      _send(method: 'PATCH', url: url, data: data);

  Future<Response<dynamic>> _delete(String url) =>
      _send(method: 'DELETE', url: url);

  Future<Response<dynamic>> _send({
    required String method,
    required String url,
    Object? data,
    Map<String, Object?>? query,
    bool anonymous = false,
    bool retryOnExpiredToken = true,
  }) async {
    final Map<String, Object> headers = <String, Object>{
      Headers.acceptHeader: Headers.jsonContentType,
    };
    if (!anonymous) {
      final String token = await _tokenLoader();
      headers['Authorization'] = 'Bearer $token';
    }
    try {
      return await _dio.request<dynamic>(
        url,
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          headers: headers,
          contentType: Headers.jsonContentType,
          // We surface non-2xx ourselves so callers see a single
          // ForumApiException type instead of branching on Dio's
          // status-based throwing.
          validateStatus: (int? _) => true,
        ),
      ).then(_throwIfError);
    } on ForumApiException catch (e) {
      // Expired session token: recover (drop + silent re-exchange) and
      // retry the request exactly once. `retryOnExpiredToken: false` on
      // the retry guarantees no loop when the fresh token is also bad.
      if (!anonymous &&
          retryOnExpiredToken &&
          e.tokenExpired &&
          _onTokenExpired != null) {
        final bool recovered = await _onTokenExpired();
        if (recovered) {
          return _send(
            method: method,
            url: url,
            data: data,
            query: query,
            retryOnExpiredToken: false,
          );
        }
      }
      rethrow;
    } on DioException catch (e) {
      // Transport-level failure (DNS, TCP refused, TLS, timeout) —
      // bubble as a synthetic 0/error so callers don't have to learn
      // Dio's exception taxonomy.
      throw ForumApiException(
        statusCode: e.response?.statusCode ?? 0,
        error: e.message ?? 'transport_error',
        cause: e,
      );
    }
  }

  Response<dynamic> _throwIfError(Response<dynamic> response) {
    final int status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) {
      return response;
    }
    String error = 'http_$status';
    final dynamic payload = response.data;
    if (payload is Map && payload['error'] is String) {
      error = payload['error'] as String;
    }
    final List<String>? expiredHeader =
        response.headers.map['token-expired'];
    final bool tokenExpired = expiredHeader != null &&
        expiredHeader.isNotEmpty &&
        expiredHeader.first.toLowerCase() == 'true';
    throw ForumApiException(
      statusCode: status,
      error: error,
      tokenExpired: tokenExpired,
    );
  }

  /// Cast Dio's `dynamic` response payload into the JSON-object shape
  /// every endpoint actually returns. Catches the "Worker returned a
  /// plain string / array where we expected an object" misconfig
  /// before it surfaces as a confusing `fromJson` cast error.
  Map<String, Object?> _asJsonObject(Response<dynamic> response) =>
      _asObject(response.data);

  static Map<String, Object?> _asObject(dynamic value) {
    if (value is Map) {
      return Map<String, Object?>.from(value);
    }
    throw ForumApiException(
      statusCode: 0,
      error: 'unexpected_response_shape: ${value.runtimeType}',
    );
  }

  static ForumCreatePostResponse _parseCreatePostResponse(
    Map<String, Object?> body,
  ) {
    final Map<String, Object?> postJson = Map<String, Object?>.of(body)
      ..remove('crisis_resources');
    final dynamic resources = body['crisis_resources'];
    return ForumCreatePostResponse(
      post: ForumPost.fromJson(postJson),
      crisisResources: resources is Map
          ? ForumCrisisResources.fromJson(
              Map<String, Object?>.from(resources),
            )
          : null,
    );
  }

  static ForumCreateCommentResponse _parseCreateCommentResponse(
    Map<String, Object?> body,
  ) {
    final Map<String, Object?> commentJson = Map<String, Object?>.of(body)
      ..remove('crisis_resources');
    final dynamic resources = body['crisis_resources'];
    return ForumCreateCommentResponse(
      comment: ForumComment.fromJson(commentJson),
      crisisResources: resources is Map
          ? ForumCrisisResources.fromJson(
              Map<String, Object?>.from(resources),
            )
          : null,
    );
  }

  static String _trimTrailingSlash(String url) {
    if (url.endsWith('/')) return url.substring(0, url.length - 1);
    return url;
  }
}

/// Riverpod-wired forum client (BUILD_SPEC.md §13 / Phase 13.9).
///
/// Watches [settingsProvider.useDemoForum] so the Settings → "Use
/// demo forum" flip flows through every community surface without a
/// hot restart. `keepAlive: true` because the session manager caches
/// the server-minted token and the demo client owns its in-memory
/// state — re-creating either per consumer would discard those caches
/// on every screen mount.
/// The demo-forum flag as its OWN provider, so [forumApiClient] (and the
/// whole sync graph above it) rebuilds only when this bool actually
/// flips. Watching the whole settings object here meant any settings
/// mutation (font-size notch, TTS toggle, quiet hours…) re-created the
/// client + SyncController, silently killing the sync poll's interval
/// timer for the rest of the session. A derived bool provider notifies
/// dependents only on value CHANGE — the riverpod-codegen equivalent of
/// `.select`.
@Riverpod(keepAlive: true)
bool useDemoForumSetting(Ref ref) =>
    ref.watch(settingsProvider).useDemoForum;

@Riverpod(keepAlive: true)
ForumApiClient forumApiClient(Ref ref) {
  final bool useDemo = ref.watch(useDemoForumSettingProvider);
  // A real backend URL baked into the build (the alpha test builds set
  // `--dart-define=FORUM_API_URL=...`) OVERRIDES the demo toggle — alpha
  // testers shouldn't have to find a Settings switch to make care circles
  // connect across devices (2026-06-06: 3 testers blocked because the
  // toggle defaulted on → per-device fake client → "invite no longer
  // valid"). So fall back to the in-memory fake only when demo is on AND
  // no backend is configured.
  final bool hasBackend = _compileTimeForumApiUrl.trim().isNotEmpty;
  if (useDemo && !hasBackend) {
    return FakeForumApiClient();
  }
  final ForumSessionManager session = ref.watch(forumSessionManagerProvider);
  return ForumApiClient(
    tokenLoader: session.currentToken,
    onTokenExpired: session.recoverFromExpiry,
  );
}

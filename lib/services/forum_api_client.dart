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
const String _compileTimeForumApiUrl = String.fromEnvironment(
  'FORUM_API_URL',
  defaultValue: 'https://forum-api.workers.dev',
);

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

/// Async producer of a bearer token for the Authorization header.
/// Production wires this to [ForumJwtMinter.currentToken]; tests
/// inject a constant closure so the API client tests stay independent
/// of the JWT signing path (which has its own coverage in
/// `test/providers/forum_jwt_provider_test.dart`).
typedef ForumTokenLoader = Future<String> Function();

/// Dio-backed thin wrapper around the Cloudflare Worker forum API
/// (BUILD_SPEC.md §13 / Phase 13.9). One method per Worker route.
///
/// Read endpoints (`GET /posts`, `GET /posts/:id`, `GET
/// /posts/:postId/comments`) skip the Authorization header to match
/// the Worker's anonymous-read posture. Every other endpoint pulls a
/// JWT via [tokenLoader] (defaulting to [ForumJwtMinter.currentToken]
/// in the riverpod wiring).
///
/// On non-2xx the client raises [ForumApiException] with the Worker's
/// `{error: '...'}` payload extracted; callers should NOT need to
/// touch [Dio]/[DioException] directly.
class ForumApiClient {
  ForumApiClient({
    required ForumTokenLoader tokenLoader,
    Dio? dio,
    String baseUrl = _compileTimeForumApiUrl,
  })  : _tokenLoader = tokenLoader,
        _dio = dio ?? Dio(),
        _baseUrl = _trimTrailingSlash(baseUrl);

  final ForumTokenLoader _tokenLoader;
  final Dio _dio;
  final String _baseUrl;

  /// Exposed for tests + diagnostics. The trailing slash is stripped
  /// at construction so callers can concat `$baseUrl/api/v1/...`
  /// without worrying about double-slashes.
  String get baseUrl => _baseUrl;

  /// The base + version prefix the API methods build paths off of.
  String get _apiBase => '$_baseUrl$forumApiVersionPrefix';

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
  }) async {
    final Map<String, Object?> body = <String, Object?>{};
    if (displayName != null) body['display_name'] = displayName;
    if (avatarUrl != null) body['avatar_url'] = avatarUrl;
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
  }) =>
      _send(method: 'POST', url: url, data: data);

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
/// hot restart. `keepAlive: true` because the underlying [ForumJwtMinter]
/// caches the minted JWT and the demo client owns its in-memory state
/// — re-creating either per consumer would discard those caches on
/// every screen mount.
@Riverpod(keepAlive: true)
ForumApiClient forumApiClient(Ref ref) {
  final bool useDemo = ref.watch(settingsProvider).useDemoForum;
  if (useDemo) {
    return FakeForumApiClient();
  }
  final ForumJwtMinter minter = ref.watch(forumJwtMinterProvider);
  return ForumApiClient(tokenLoader: minter.currentToken);
}

import 'package:alchemist/alchemist.dart';
import 'package:holdclose/models/forum.dart';
import 'package:holdclose/screens/community/post_detail_screen.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/community/comment_thread.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

ForumPost _post({
  String id = 'p',
  String title = 'Sundowning hit hard at dusk again',
  String body =
      "We dimmed the lights and put on her favorite Sinatra record. "
          "She settled in about ten minutes — sharing in case it helps "
          'another Careblazer tonight.',
  int voteCount = 12,
  int commentCount = 3,
  Duration age = const Duration(minutes: 18),
  String? username = 'sundown_sarah',
}) =>
    ForumPost(
      id: id,
      authorId: 'profile-$id',
      authorUsername: username,
      title: title,
      body: body,
      createdAt: _fixedNow.subtract(age),
      updatedAt: _fixedNow.subtract(age),
      voteCount: voteCount,
      hidden: false,
      commentCount: commentCount,
    );

ForumComment _c(
  String id, {
  String? parent,
  int depth = 0,
  int voteCount = 0,
  bool hidden = false,
  String body = 'hello',
}) =>
    ForumComment(
      id: id,
      postId: 'p',
      parentCommentId: parent,
      authorId: hidden ? null : 'profile-$id',
      body: hidden ? null : body,
      createdAt: _fixedNow.subtract(const Duration(minutes: 5)),
      voteCount: voteCount,
      depth: depth,
      hidden: hidden,
    );

/// Deterministic [ForumApiClient] used by the goldens — hands back a
/// fixed post + comment list regardless of args so the rendered tree
/// is identical run-to-run.
class _CannedForumApiClient extends ForumApiClient {
  _CannedForumApiClient({
    required ForumPost post,
    required List<ForumComment> comments,
  })  : _post = post,
        _comments = comments,
        super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final ForumPost _post;
  final List<ForumComment> _comments;

  @override
  Future<ForumPost> getPost(String postId) async => _post;

  @override
  Future<List<ForumComment>> listComments({
    required String postId,
    ForumCommentSort sort = ForumCommentSort.top,
  }) async =>
      _comments;
}

/// Fails the post fetch with a transport error (statusCode 0) so the golden
/// captures the offline retry surface (#19). No initialPost is handed in, so
/// the screen must fetch — and that fetch fails.
class _OfflineForumApiClient extends ForumApiClient {
  _OfflineForumApiClient()
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  @override
  Future<ForumPost> getPost(String postId) async {
    throw ForumApiException(statusCode: 0, error: 'transport_error');
  }

  @override
  Future<List<ForumComment>> listComments({
    required String postId,
    ForumCommentSort sort = ForumCommentSort.top,
  }) async {
    throw ForumApiException(statusCode: 0, error: 'transport_error');
  }
}

Widget _wrap({
  required ForumPost post,
  required List<ForumComment> comments,
  Size size = const Size(420, 1200),
}) {
  return ProviderScope(
    overrides: <Override>[
      forumApiClientProvider.overrideWithValue(
        _CannedForumApiClient(post: post, comments: comments),
      ),
      postDetailClockProvider.overrideWithValue(() => _fixedNow),
    ],
    child: SizedBox(
      width: size.width,
      height: size.height,
      child: MaterialApp(
        builder: (BuildContext _, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
        home: PostDetailScreen(postId: post.id, initialPost: post),
      ),
    ),
  );
}

void main() {
  group('PostDetailScreen golden — BUILD_SPEC.md §13 / Phase 13.11', () {
    goldenTest(
      '0 comments — empty state',
      fileName: 'post_detail_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'no comments yet',
            child: _wrap(
              post: _post(commentCount: 0),
              comments: const <ForumComment>[],
              size: const Size(420, 900),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'offline — branded retry surface (#19)',
      fileName: 'post_detail_screen_offline',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'transport error (#19)',
            child: ProviderScope(
              overrides: <Override>[
                forumApiClientProvider
                    .overrideWithValue(_OfflineForumApiClient()),
                postDetailClockProvider.overrideWithValue(() => _fixedNow),
              ],
              child: SizedBox(
                width: 420,
                height: 900,
                child: MaterialApp(
                  builder: (BuildContext _, Widget? child) => ColoredBox(
                    color: holdcloseColors.background,
                    child: child ?? const SizedBox.shrink(),
                  ),
                  // No initialPost → the screen fetches, and the fetch fails.
                  home: const PostDetailScreen(postId: 'p'),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'single root-level comment',
      fileName: 'post_detail_screen_single',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'one root comment',
            child: _wrap(
              post: _post(commentCount: 1),
              comments: <ForumComment>[
                _c('c1',
                    voteCount: 3,
                    body: "You're not alone — sundowning is brutal. Sinatra is "
                        'genius. Thank you.'),
              ],
              size: const Size(420, 900),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      '3-level deep thread',
      fileName: 'post_detail_screen_three_deep',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'three-level thread',
            child: _wrap(
              post: _post(commentCount: 3),
              comments: <ForumComment>[
                _c('r', voteCount: 4, body: "Same here at our place."),
                _c('m',
                    parent: 'r',
                    depth: 1,
                    voteCount: 2,
                    body: 'What helped us was a warm-toned lamp.'),
                _c('l',
                    parent: 'm',
                    depth: 2,
                    voteCount: 1,
                    body: 'Trying that tonight, thank you.'),
              ],
              size: const Size(420, 1000),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      '6-level deep — reply button hidden at max depth',
      fileName: 'post_detail_screen_max_depth',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'max-depth leaf',
            child: _wrap(
              post: _post(commentCount: 7),
              comments: <ForumComment>[
                for (int d = 0; d <= maxCommentDepth; d++)
                  _c(
                    'lvl-$d',
                    parent: d == 0 ? null : 'lvl-${d - 1}',
                    depth: d,
                    voteCount: maxCommentDepth - d,
                    body: 'Reply at depth $d.',
                  ),
              ],
              size: const Size(420, 1300),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'hidden comments render as placeholders',
      fileName: 'post_detail_screen_hidden',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'hidden parent with visible child',
            child: _wrap(
              post: _post(commentCount: 2),
              comments: <ForumComment>[
                _c('hidden-one', hidden: true),
                _c(
                  'still-visible',
                  parent: 'hidden-one',
                  depth: 1,
                  voteCount: 2,
                  body: "Sending love. You're doing the work.",
                ),
              ],
              size: const Size(420, 900),
            ),
          ),
        ],
      ),
    );
  });
}

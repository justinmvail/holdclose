import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/forum.dart';
import 'package:careblazers/screens/community/community_feed_screen.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

ForumPost _post(
  String id, {
  required String title,
  required String body,
  required int voteCount,
  required int commentCount,
  required Duration age,
  String? username,
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

/// Same fake-client shape the widget tests use — just hands back a
/// deterministic per-sort page so the golden gets the exact same
/// render every run.
class _CannedForumApiClient extends ForumApiClient {
  _CannedForumApiClient(this._page)
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final List<ForumPost> _page;

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async {
    if (before != null) return const <ForumPost>[];
    return _page;
  }
}

/// Always fails the first-page fetch with a transport error (statusCode 0)
/// so the golden captures the offline retry surface (#19).
class _OfflineForumApiClient extends ForumApiClient {
  _OfflineForumApiClient()
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async {
    throw ForumApiException(statusCode: 0, error: 'transport_error');
  }
}

void main() {
  group('CommunityFeedScreen golden', () {
    goldenTest(
      'empty state — Be the first to post',
      fileName: 'community_feed_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 13.10)',
            child: ProviderScope(
              overrides: <Override>[
                forumApiClientProvider.overrideWithValue(
                  _CannedForumApiClient(const <ForumPost>[]),
                ),
                communityFeedClockProvider.overrideWithValue(() => _fixedNow),
              ],
              child: SizedBox(
                width: 420,
                height: 900,
                child: MaterialApp(
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                  home: const CommunityFeedScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'offline state — branded retry surface (#19)',
      fileName: 'community_feed_screen_offline',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'transport error (#19)',
            child: ProviderScope(
              overrides: <Override>[
                forumApiClientProvider.overrideWithValue(
                  _OfflineForumApiClient(),
                ),
                communityFeedClockProvider.overrideWithValue(() => _fixedNow),
              ],
              child: SizedBox(
                width: 420,
                height: 900,
                child: MaterialApp(
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                  home: const CommunityFeedScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'populated state — Hot feed with three posts',
      fileName: 'community_feed_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 13.10)',
            child: ProviderScope(
              overrides: <Override>[
                forumApiClientProvider.overrideWithValue(
                  _CannedForumApiClient(<ForumPost>[
                    _post(
                      'a',
                      title: 'Sundowning hit hard at dusk again',
                      body:
                          "We dimmed the lights and put on her favorite Sinatra "
                          'record. She settled in about ten minutes — sharing in '
                          'case it helps another Careblazer tonight.',
                      voteCount: 12,
                      commentCount: 5,
                      age: const Duration(minutes: 18),
                      username: 'sundown_sarah',
                    ),
                    _post(
                      'b',
                      title: 'Refusing the morning meds — what worked for you?',
                      body:
                          'Hiding the pill in applesauce stopped working this '
                          'week. Doctor cleared a crushable alternative, but I '
                          'want to hear what other folks do for the routine '
                          'itself.',
                      voteCount: 7,
                      commentCount: 9,
                      age: const Duration(hours: 3),
                    ),
                    _post(
                      'c',
                      title: 'Mom asked for Dad today (he passed in 2019)',
                      body:
                          "I told her he was at the store and would be home "
                          'soon. She lit up. Felt strange lying — but the '
                          'comfort was real.',
                      voteCount: 24,
                      commentCount: 14,
                      age: const Duration(days: 2),
                    ),
                  ]),
                ),
                communityFeedClockProvider.overrideWithValue(() => _fixedNow),
              ],
              child: SizedBox(
                width: 420,
                height: 1100,
                child: MaterialApp(
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                  home: const CommunityFeedScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

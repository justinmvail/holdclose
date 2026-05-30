import 'package:careblazers/models/forum.dart';
import 'package:careblazers/screens/community/community_feed_screen.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../_semantics_matchers.dart';

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

ForumPost _post(
  String id, {
  String? title,
  String? body,
  int voteCount = 0,
  int commentCount = 0,
  Duration age = const Duration(hours: 2),
}) =>
    ForumPost(
      id: id,
      authorId: 'profile-$id',
      title: title ?? 'Post $id',
      body: body ?? 'Body of $id',
      createdAt: _fixedNow.subtract(age),
      updatedAt: _fixedNow.subtract(age),
      voteCount: voteCount,
      hidden: false,
      commentCount: commentCount,
    );

/// Fake [ForumApiClient] that hand-builds the per-sort, per-cursor
/// pages the widget tests rely on. Same shape as the notifier test's
/// fake, repeated here to keep each test file independently runnable.
class _FakeForumApiClient extends ForumApiClient {
  _FakeForumApiClient()
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final Map<String, List<ForumPost>> _pages = <String, List<ForumPost>>{};
  Object? nextError;
  int callCount = 0;

  void setPage({
    required ForumPostSort sort,
    String? before,
    required List<ForumPost> page,
  }) {
    _pages['${sort.queryValue}|${before ?? ''}'] = page;
  }

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async {
    callCount++;
    if (nextError != null) {
      final Object err = nextError!;
      nextError = null;
      throw err;
    }
    return _pages['${sort.queryValue}|${before ?? ''}'] ?? const <ForumPost>[];
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeForumApiClient client,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(client),
        communityFeedClockProvider.overrideWithValue(() => _fixedNow),
      ],
      child: const MaterialApp(home: CommunityFeedScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('CommunityFeedScreen — BUILD_SPEC.md §13 / Phase 13.10', () {
    testWidgets('shows the empty-state copy when the feed has zero posts',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(sort: ForumPostSort.hot, page: const <ForumPost>[]);
      await _pump(tester, client: client);

      expect(find.byKey(CommunityFeedScreen.emptyStateKey), findsOneWidget);
      expect(find.text('Be the first to post.'), findsOneWidget);
      expect(find.byKey(CommunityFeedScreen.listKey), findsNothing);
    });

    testWidgets('renders one card per post in the populated state',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(
          sort: ForumPostSort.hot,
          page: <ForumPost>[
            _post('a',
                title: 'Sundowning advice',
                body: 'Anyone else struggling at dusk?',
                voteCount: 4,
                commentCount: 2),
            _post('b',
                title: 'Refusing care',
                body: 'How do you handle bath time?',
                voteCount: 7,
                commentCount: 5),
          ],
        );
      await _pump(tester, client: client);

      expect(find.byKey(CommunityFeedScreen.listKey), findsOneWidget);
      expect(find.byKey(CommunityFeedScreen.postTileKey('a')), findsOneWidget);
      expect(find.byKey(CommunityFeedScreen.postTileKey('b')), findsOneWidget);
      expect(find.text('Sundowning advice'), findsOneWidget);
      expect(find.text('Refusing care'), findsOneWidget);
    });

    testWidgets('post card surfaces vote and comment counts',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(
          sort: ForumPostSort.hot,
          page: <ForumPost>[_post('a', voteCount: 12, commentCount: 4)],
        );
      await _pump(tester, client: client);

      final Finder tile = find.byKey(CommunityFeedScreen.postTileKey('a'));
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.text('12')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tile, matching: find.text('4')),
        findsOneWidget,
      );
    });

    testWidgets('body preview clamps to three lines',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(
          sort: ForumPostSort.hot,
          page: <ForumPost>[
            _post(
              'a',
              body: 'line 1\nline 2\nline 3\nline 4 should not render',
            ),
          ],
        );
      await _pump(tester, client: client);

      final Finder bodyFinder = find.descendant(
        of: find.byKey(CommunityFeedScreen.postTileKey('a')),
        matching: find.byWidgetPredicate(
          (Widget w) => w is Text && w.data?.startsWith('line 1') == true,
        ),
      );
      expect(bodyFinder, findsOneWidget);
      final Text body = tester.widget<Text>(bodyFinder);
      expect(body.maxLines, 3);
      expect(body.overflow, TextOverflow.ellipsis);
    });

    testWidgets('tapping a sort chip swaps the active feed',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(
          sort: ForumPostSort.hot,
          page: <ForumPost>[_post('hot-1', title: 'Hot post')],
        )
        ..setPage(
          sort: ForumPostSort.top,
          page: <ForumPost>[_post('top-1', title: 'Top post')],
        );
      await _pump(tester, client: client);

      expect(find.text('Hot post'), findsOneWidget);

      await tester.tap(find.byKey(CommunityFeedScreen.sortTopKey));
      await tester.pumpAndSettle();

      expect(find.text('Top post'), findsOneWidget);
      expect(find.text('Hot post'), findsNothing);
    });

    testWidgets('pull-to-refresh fires a fresh page-1 fetch',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(
          sort: ForumPostSort.hot,
          page: <ForumPost>[_post('a', title: 'Original')],
        );
      await _pump(tester, client: client);
      expect(client.callCount, 1);

      // Replace the canned page so the refresh observes new data.
      client.setPage(
        sort: ForumPostSort.hot,
        page: <ForumPost>[_post('a', title: 'Refreshed')],
      );

      // Drag the list down to trigger the RefreshIndicator.
      await tester.fling(
        find.byKey(CommunityFeedScreen.listKey),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      expect(client.callCount, greaterThanOrEqualTo(2));
      expect(find.text('Refreshed'), findsOneWidget);
    });

    testWidgets('initial-load failure shows a retry surface',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..nextError = Exception('boom')
        ..setPage(
          sort: ForumPostSort.hot,
          page: <ForumPost>[_post('a', title: 'After retry')],
        );
      await _pump(tester, client: client);

      expect(find.byKey(CommunityFeedScreen.errorKey), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('After retry'), findsOneWidget);
      expect(find.byKey(CommunityFeedScreen.errorKey), findsNothing);
    });

    testWidgets('sort chips carry screen-reader labels',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..setPage(sort: ForumPostSort.hot, page: const <ForumPost>[]);
      await _pump(tester, client: client);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Hot sort.*Double-tap'),
        ),
        isTrue,
      );
    });
  });

  group('Helpers', () {
    test('relativeTime renders the expected bucket strings', () {
      final DateTime now = DateTime.utc(2026, 5, 30, 12);
      expect(
        relativeTime(now.subtract(const Duration(seconds: 10)), now),
        'just now',
      );
      expect(
        relativeTime(now.subtract(const Duration(minutes: 5)), now),
        '5m ago',
      );
      expect(
        relativeTime(now.subtract(const Duration(hours: 3)), now),
        '3h ago',
      );
      expect(
        relativeTime(now.subtract(const Duration(days: 4)), now),
        '4d ago',
      );
      expect(
        relativeTime(now.subtract(const Duration(days: 90)), now),
        matches(RegExp(r'[A-Z][a-z]+ \d+')),
      );
      // Future timestamps (clock skew) clamp to "just now".
      expect(
        relativeTime(now.add(const Duration(minutes: 2)), now),
        'just now',
      );
    });

    test('displayNameForAuthor strips known prefixes and pads short ids', () {
      expect(displayNameForAuthor('profile-abc123'), 'Caregiver_abc123');
      expect(displayNameForAuthor('user-xyz'), 'Caregiver_xyz');
      expect(displayNameForAuthor('plainid'), 'Caregiver_plaini');
      expect(displayNameForAuthor(''), 'Caregiver');
    });
  });
}

import 'package:holdclose/models/forum.dart';
import 'package:holdclose/providers/home_clock_provider.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/home/community_recap_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

ForumPost _post(
  String id, {
  String title = 'A post',
  int voteCount = 0,
  int commentCount = 0,
}) =>
    ForumPost(
      id: id,
      authorId: 'profile-$id',
      title: title,
      body: 'Body of $id',
      createdAt: DateTime.utc(2026, 5, 30, 12),
      updatedAt: DateTime.utc(2026, 5, 30, 12),
      voteCount: voteCount,
      hidden: false,
      commentCount: commentCount,
    );

/// Fake [ForumApiClient] whose [listPosts] replies with a fixed page —
/// the recap card reads the live [communityFeedProvider], so a fake here
/// drives the feed's first fetch without any new fetch path. [error]
/// forces the fetch to fail so the fail-safe collapse can be exercised.
class _FakeForumApiClient extends ForumApiClient {
  _FakeForumApiClient({this.page = const <ForumPost>[], this.error})
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final List<ForumPost> page;
  final Object? error;

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async {
    if (error != null) throw error!;
    return page;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeForumApiClient client,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(client),
        homeClockProvider.overrideWithValue(() => DateTime.utc(2026, 5, 30, 13)),
      ],
      child: MaterialApp(
        theme: holdcloseLightTheme,
        home: const Scaffold(
          body: SingleChildScrollView(child: CommunityRecapCard()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('CommunityRecapCard', () {
    testWidgets('renders the top recent posts with an activity hint',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(
        page: <ForumPost>[
          _post('a', title: 'Sundowning tips', voteCount: 5, commentCount: 3),
          _post('b', title: 'Refusing to bathe', voteCount: 1, commentCount: 1),
          _post('c', title: 'Wandering at night', voteCount: 0, commentCount: 0),
        ],
      );
      await _pump(tester, client: client);

      expect(find.byKey(CommunityRecapCard.cardKey), findsOneWidget);
      expect(find.text('From the Community'), findsOneWidget);
      expect(find.text('Sundowning tips'), findsOneWidget);
      expect(find.text('Refusing to bathe'), findsOneWidget);
      expect(find.text('Wandering at night'), findsOneWidget);

      // Activity hint pluralizes votes/replies correctly.
      expect(find.textContaining('5 votes  ·  3 replies'), findsOneWidget);
      expect(find.textContaining('1 vote  ·  1 reply'), findsOneWidget);
    });

    testWidgets('caps the recap at three posts', (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(
        page: <ForumPost>[
          _post('a', title: 'One'),
          _post('b', title: 'Two'),
          _post('c', title: 'Three'),
          _post('d', title: 'Four'),
          _post('e', title: 'Five'),
        ],
      );
      await _pump(tester, client: client);

      expect(find.text('One'), findsOneWidget);
      expect(find.text('Three'), findsOneWidget);
      // Fourth + beyond are dropped — the card is a glance, not a feed.
      expect(find.text('Four'), findsNothing);
      expect(find.text('Five'), findsNothing);
    });

    testWidgets('collapses to nothing when there are no posts',
        (WidgetTester tester) async {
      await _pump(tester, client: _FakeForumApiClient());

      expect(find.byKey(CommunityRecapCard.cardKey), findsNothing);
      expect(find.text('From the Community'), findsNothing);
    });

    testWidgets('collapses to nothing (never errors) when the fetch fails',
        (WidgetTester tester) async {
      await _pump(
        tester,
        client: _FakeForumApiClient(error: Exception('backend down')),
      );

      expect(find.byKey(CommunityRecapCard.cardKey), findsNothing);
      expect(find.text('From the Community'), findsNothing);
      // Home never throws a red box at a caregiver — no error text either.
      expect(tester.takeException(), isNull);
    });
  });
}

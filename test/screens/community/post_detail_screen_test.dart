import 'package:careblazers/models/forum.dart';
import 'package:careblazers/screens/community/post_detail_screen.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/widgets/community/comment_thread.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

ForumPost _post({
  String id = 'p',
  String title = 'Sundowning again',
  String body = 'Lights helped tonight.',
  int voteCount = 3,
  int commentCount = 2,
  Duration age = const Duration(minutes: 30),
}) =>
    ForumPost(
      id: id,
      authorId: 'profile-$id',
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
  String body = 'comment body',
}) =>
    ForumComment(
      id: id,
      postId: 'p',
      parentCommentId: parent,
      authorId: hidden ? null : 'profile-$id',
      body: hidden ? null : body,
      createdAt: _fixedNow,
      voteCount: voteCount,
      depth: depth,
      hidden: hidden,
    );

class _FakeForumApiClient extends ForumApiClient {
  _FakeForumApiClient()
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  ForumPost postToReturn = _post();
  List<ForumComment> commentsToReturn = const <ForumComment>[];
  ForumVoteResponse Function(int) voteResponse =
      (int v) => ForumVoteResponse(voteCount: 99, value: v);
  Object? nextListCommentsError;

  int listCommentsCalls = 0;
  int voteCalls = 0;
  int createCommentCalls = 0;
  int reportCalls = 0;
  String? lastReportReason;

  @override
  Future<ForumPost> getPost(String postId) async => postToReturn;

  @override
  Future<List<ForumComment>> listComments({
    required String postId,
    ForumCommentSort sort = ForumCommentSort.top,
  }) async {
    listCommentsCalls++;
    if (nextListCommentsError != null) {
      final Object err = nextListCommentsError!;
      nextListCommentsError = null;
      throw err;
    }
    return commentsToReturn;
  }

  @override
  Future<ForumVoteResponse> castVote({
    required ForumVoteTarget targetKind,
    required String targetId,
    required int value,
  }) async {
    voteCalls++;
    return voteResponse(value);
  }

  @override
  Future<ForumCreateCommentResponse> createComment({
    required String postId,
    required String body,
    String? parentCommentId,
  }) async {
    createCommentCalls++;
    return ForumCreateCommentResponse(
      comment: _c(
        'new-$createCommentCalls',
        parent: parentCommentId,
        depth: parentCommentId == null ? 0 : 1,
        body: body,
      ),
    );
  }

  @override
  Future<ForumReport> submitReport({
    required ForumVoteTarget targetKind,
    required String targetId,
    required String reason,
  }) async {
    reportCalls++;
    lastReportReason = reason;
    return ForumReport(
      id: 'r-$reportCalls',
      targetKind: targetKind.queryValue,
      targetId: targetId,
      reporterId: 'reporter',
      reason: reason,
      status: 'pending',
      createdAt: _fixedNow,
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeForumApiClient client,
  ForumPost? initialPost,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(client),
        postDetailClockProvider.overrideWithValue(() => _fixedNow),
      ],
      child: MaterialApp(
        home: PostDetailScreen(
          postId: client.postToReturn.id,
          initialPost: initialPost,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('PostDetailScreen — Phase 13.11', () {
    testWidgets('renders the post header + empty-comments placeholder',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post(title: 'Sundowning advice');
      await _pump(tester, client: client);

      expect(find.text('Sundowning advice'), findsOneWidget);
      expect(find.byKey(PostDetailScreen.emptyCommentsKey), findsOneWidget);
      expect(find.text('Be the first to reply.'), findsOneWidget);
    });

    testWidgets('renders comments in tree order with 24px indent per depth',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post()
        ..commentsToReturn = <ForumComment>[
          _c('r', body: 'root reply'),
          _c('m', parent: 'r', depth: 1, body: 'middle'),
          _c('l', parent: 'm', depth: 2, body: 'leaf'),
        ];
      await _pump(tester, client: client);

      expect(find.byKey(PostDetailScreen.commentsKey), findsOneWidget);
      expect(find.byKey(CommentThread.rowKey('r')), findsOneWidget);
      expect(find.byKey(CommentThread.rowKey('m')), findsOneWidget);
      expect(find.byKey(CommentThread.rowKey('l')), findsOneWidget);

      // The deeper rows should sit further right than the root row.
      final double rRowLeft = tester
          .getTopLeft(find.byKey(CommentThread.rowKey('r')))
          .dx;
      final double mRowLeft = tester
          .getTopLeft(find.byKey(CommentThread.rowKey('m')))
          .dx;
      final double lRowLeft = tester
          .getTopLeft(find.byKey(CommentThread.rowKey('l')))
          .dx;
      // 24px per depth — the middle row is at depth 1, leaf at depth 2,
      // so the leaf indents by exactly the depth-step beyond the middle.
      expect(mRowLeft - rRowLeft, closeTo(commentIndentStep, 0.5));
      expect(lRowLeft - mRowLeft, closeTo(commentIndentStep, 0.5));
    });

    testWidgets('skips post fetch when initialPost is provided',
        (WidgetTester tester) async {
      final ForumPost seeded = _post(title: 'pre-loaded title');
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = seeded;
      await _pump(tester, client: client, initialPost: seeded);

      expect(find.text('pre-loaded title'), findsOneWidget);
      expect(client.listCommentsCalls, 1);
    });

    testWidgets('tapping the post upvote dispatches a +1 vote',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post(voteCount: 3)
        ..voteResponse = (int v) => ForumVoteResponse(voteCount: 4, value: v);
      await _pump(tester, client: client);

      await tester.tap(find.byKey(PostDetailScreen.postUpvoteKey));
      await tester.pumpAndSettle();

      expect(client.voteCalls, 1);
      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('opening the root reply composer + sending posts a comment',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post();
      await _pump(tester, client: client);

      // Open the composer.
      await tester.tap(find.byKey(PostDetailScreen.rootReplyButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(InlineReplyComposer.rootKey), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('reply-composer-root-field')),
        'thanks for sharing',
      );
      await tester.tap(find.byKey(const Key('reply-composer-root-send')));
      await tester.pumpAndSettle();

      expect(client.createCommentCalls, 1);
      // New comment appears in the thread after the round-trip.
      expect(find.text('thanks for sharing'), findsOneWidget);
    });

    testWidgets('long-press on a comment surfaces the report sheet',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post()
        ..commentsToReturn = <ForumComment>[_c('c1')];
      await _pump(tester, client: client);

      await tester.longPress(find.byKey(CommentThread.rowKey('c1')));
      await tester.pumpAndSettle();

      expect(find.text('Report this comment'), findsOneWidget);
      await tester.tap(find.byKey(const Key('report-reason-spam')));
      await tester.pumpAndSettle();

      expect(client.reportCalls, 1);
      expect(client.lastReportReason, 'spam');
    });

    testWidgets('hidden comments render as the [removed] placeholder',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post()
        ..commentsToReturn = <ForumComment>[
          _c('hidden-one', hidden: true),
          _c('visible-child',
              parent: 'hidden-one', depth: 1, body: 'still here'),
        ];
      await _pump(tester, client: client);
      expect(find.text(hiddenCommentPlaceholder), findsOneWidget);
      // Reply chain below the hidden parent remains visible.
      expect(find.text('still here'), findsOneWidget);
    });

    testWidgets('initial-load failure shows the retry surface',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post()
        ..nextListCommentsError = Exception('boom');
      await _pump(tester, client: client);

      expect(find.byKey(PostDetailScreen.errorKey), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}

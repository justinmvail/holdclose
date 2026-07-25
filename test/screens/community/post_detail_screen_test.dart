import 'package:holdclose/models/forum.dart';
import 'package:holdclose/screens/community/post_detail_screen.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/widgets/community/comment_thread.dart';
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
  _FakeForumApiClient({this.myProfileId = 'profile-someone-else'})
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  /// The signed-in caregiver's profile id `GET /profiles/me` returns. The
  /// default does NOT match the seeded `profile-p` author, so ownership
  /// controls stay hidden unless a test points this at the post's author.
  final String myProfileId;

  ForumPost postToReturn = _post();
  List<ForumComment> commentsToReturn = const <ForumComment>[];
  ForumVoteResponse Function(int) voteResponse =
      (int v) => ForumVoteResponse(voteCount: 99, value: v);
  Object? nextListCommentsError;

  /// One-shot error thrown by the next [getPost] call, then cleared — lets a
  /// test model the whole-load transport failure (no post lands at all).
  Object? nextGetPostError;
  int getPostCalls = 0;

  int listCommentsCalls = 0;
  int voteCalls = 0;
  int createCommentCalls = 0;
  int reportCalls = 0;
  String? lastReportReason;
  int updatePostCalls = 0;
  String? lastUpdatePostBody;
  int deletePostCalls = 0;
  final List<String> deletedCommentIds = <String>[];

  @override
  Future<ForumProfile> getMyProfile() async => ForumProfile(
        id: myProfileId,
        holdcloseUserId: 'cb-me',
        displayName: 'Me',
        joinedAt: _fixedNow.subtract(const Duration(days: 30)),
        role: 'user',
      );

  @override
  Future<ForumPost> getPost(String postId) async {
    getPostCalls++;
    if (nextGetPostError != null) {
      final Object err = nextGetPostError!;
      nextGetPostError = null;
      throw err;
    }
    return postToReturn;
  }

  @override
  Future<ForumPost> updatePost({
    required String postId,
    required String body,
  }) async {
    updatePostCalls++;
    lastUpdatePostBody = body;
    return postToReturn = postToReturn.copyWith(body: body);
  }

  @override
  Future<void> deletePost(String postId) async {
    deletePostCalls++;
  }

  @override
  Future<void> deleteComment(String commentId) async {
    deletedCommentIds.add(commentId);
  }

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

    testWidgets(
        'a transport error (statusCode 0) shows the branded "check your '
        'connection" view; Retry re-fetches and renders the post (#19)',
        (WidgetTester tester) async {
      // getPost itself fails transport-style (statusCode 0) so the whole
      // load fails with no post in hand — the blank-screen case #19 targets.
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post(title: 'Recovered post')
        ..nextGetPostError = ForumApiException(
          statusCode: 0,
          error: 'transport_error',
        );
      // No initialPost handoff → the screen must fetch, and that fetch fails.
      await _pump(tester, client: client);

      expect(find.byKey(PostDetailScreen.errorKey), findsOneWidget);
      expect(find.text("We couldn't load this post."), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      // The post never rendered.
      expect(find.text('Recovered post'), findsNothing);

      final int getsBefore = client.getPostCalls;

      // Retry → the next getPost resolves (error was one-shot) → post renders.
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(client.getPostCalls, greaterThan(getsBefore));
      expect(find.byKey(PostDetailScreen.errorKey), findsNothing);
      expect(find.text('Recovered post'), findsOneWidget);
    });
  });

  group('PostDetailScreen — owner edit/delete gating', () {
    testWidgets(
      "another caregiver's post shows the report flag, no owner menu",
      (WidgetTester tester) async {
        // Default fake profile id ('profile-someone-else') != the post
        // author ('profile-p'), so this is NOT the caregiver's own post.
        final _FakeForumApiClient client = _FakeForumApiClient()
          ..postToReturn = _post();
        await _pump(tester, client: client);

        expect(find.byKey(PostDetailScreen.postReportKey), findsOneWidget);
        expect(find.byKey(PostDetailScreen.postOwnerMenuKey), findsNothing);
      },
    );

    testWidgets(
      'own post shows the owner menu (Edit + Delete), not the report flag',
      (WidgetTester tester) async {
        // Point the signed-in profile at the post's author → owned.
        final _FakeForumApiClient client =
            _FakeForumApiClient(myProfileId: 'profile-p')
              ..postToReturn = _post();
        await _pump(tester, client: client);

        expect(find.byKey(PostDetailScreen.postOwnerMenuKey), findsOneWidget);
        expect(find.byKey(PostDetailScreen.postReportKey), findsNothing);

        await tester.tap(find.byKey(PostDetailScreen.postOwnerMenuKey));
        await tester.pumpAndSettle();
        expect(find.byKey(PostDetailScreen.postEditKey), findsOneWidget);
        expect(find.byKey(PostDetailScreen.postDeleteKey), findsOneWidget);
      },
    );

    testWidgets(
      'Delete post → confirm dialog → "Keep it" leaves the post in place',
      (WidgetTester tester) async {
        final _FakeForumApiClient client =
            _FakeForumApiClient(myProfileId: 'profile-p')
              ..postToReturn = _post();
        await _pump(tester, client: client);

        await tester.tap(find.byKey(PostDetailScreen.postOwnerMenuKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(PostDetailScreen.postDeleteKey));
        await tester.pumpAndSettle();

        // The confirm dialog is up.
        expect(find.text('Delete this post?'), findsOneWidget);

        // Backing out keeps the post — no delete call.
        await tester.tap(find.byKey(PostDetailScreen.postDeleteCancelKey));
        await tester.pumpAndSettle();
        expect(client.deletePostCalls, 0);
      },
    );

    testWidgets(
      'own comment exposes a delete trigger; another caregiver\'s shows '
      'the report flag',
      (WidgetTester tester) async {
        // The signed-in profile authored 'mine'; 'theirs' belongs to someone
        // else (author 'profile-theirs').
        final _FakeForumApiClient client =
            _FakeForumApiClient(myProfileId: 'profile-mine')
              ..postToReturn = _post()
              ..commentsToReturn = <ForumComment>[
                _c('mine', body: 'my reply'),
                _c('theirs', body: 'their reply'),
              ];
        await _pump(tester, client: client);

        // Own comment → delete trigger, no report flag.
        expect(
          find.byKey(CommentThread.deleteTriggerKey('mine')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('comment-report-mine')), findsNothing);

        // Other's comment → report flag, no delete trigger.
        expect(
          find.byKey(CommentThread.deleteTriggerKey('theirs')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('comment-report-theirs')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'long-press own comment → delete sheet → Delete reply removes it',
      (WidgetTester tester) async {
        final _FakeForumApiClient client =
            _FakeForumApiClient(myProfileId: 'profile-mine')
              ..postToReturn = _post()
              ..commentsToReturn = <ForumComment>[
                _c('mine', body: 'my reply'),
              ];
        await _pump(tester, client: client);

        await tester.longPress(find.byKey(CommentThread.rowKey('mine')));
        await tester.pumpAndSettle();

        // The own-comment sheet (not the report sheet) is up.
        expect(find.text('Your reply'), findsOneWidget);
        expect(find.text('Report this comment'), findsNothing);

        await tester.tap(find.byKey(CommentThread.deleteKey('mine')));
        await tester.pumpAndSettle();

        // The backend received the delete and the row left the thread.
        expect(client.deletedCommentIds, <String>['mine']);
        expect(find.byKey(CommentThread.rowKey('mine')), findsNothing);
        expect(find.text('Reply deleted.'), findsOneWidget);
      },
    );
  });
}

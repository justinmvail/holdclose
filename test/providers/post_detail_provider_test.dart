import 'package:holdclose/models/forum.dart';
import 'package:holdclose/providers/post_detail_provider.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

ForumPost _post(
  String id, {
  int voteCount = 0,
  int commentCount = 0,
}) =>
    ForumPost(
      id: id,
      authorId: 'profile-$id',
      title: 'Post $id',
      body: 'Body of $id',
      createdAt: _fixedNow,
      updatedAt: _fixedNow,
      voteCount: voteCount,
      hidden: false,
      commentCount: commentCount,
    );

ForumComment _comment(
  String id, {
  String postId = 'p',
  String? parent,
  int depth = 0,
  int voteCount = 0,
  bool hidden = false,
  String body = 'hello',
}) =>
    ForumComment(
      id: id,
      postId: postId,
      parentCommentId: parent,
      authorId: hidden ? null : 'profile-$id',
      body: hidden ? null : body,
      createdAt: _fixedNow,
      voteCount: voteCount,
      depth: depth,
      hidden: hidden,
    );

/// Stub [ForumApiClient] backing the [PostDetail] notifier-under-test.
/// Exposes the same `setX` configuration knobs the screen test uses so
/// both layers can describe their fixtures with the same vocabulary.
class _FakeForumApiClient extends ForumApiClient {
  _FakeForumApiClient()
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  ForumPost? postToReturn;
  List<ForumComment> commentsToReturn = const <ForumComment>[];
  Object? nextGetPostError;
  Object? nextListCommentsError;
  Object? nextVoteError;
  Object? nextCreateCommentError;
  Object? nextReportError;
  Object? nextDeletePostError;
  Object? nextDeleteCommentError;

  int getPostCalls = 0;
  int listCommentsCalls = 0;
  int voteCalls = 0;
  int createCommentCalls = 0;
  int reportCalls = 0;
  final List<String> deletedPostIds = <String>[];
  final List<String> deletedCommentIds = <String>[];

  ForumVoteResponse Function(ForumVoteTarget kind, String id, int value)
      voteResponseFor =
      (ForumVoteTarget _, String __, int value) =>
          ForumVoteResponse(voteCount: value, value: value);

  ForumComment Function(String? parent, String body) commentBuilder =
      (String? parent, String body) => _comment(
            'reply-${parent ?? 'root'}',
            parent: parent,
            depth: parent == null ? 0 : 1,
            body: body,
          );

  ForumCrisisResources? crisisResourcesOnReply;

  @override
  Future<ForumPost> getPost(String postId) async {
    getPostCalls++;
    if (nextGetPostError != null) {
      final Object err = nextGetPostError!;
      nextGetPostError = null;
      throw err;
    }
    return postToReturn ?? _post(postId);
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
    if (nextVoteError != null) {
      final Object err = nextVoteError!;
      nextVoteError = null;
      throw err;
    }
    return voteResponseFor(targetKind, targetId, value);
  }

  @override
  Future<ForumCreateCommentResponse> createComment({
    required String postId,
    required String body,
    String? parentCommentId,
  }) async {
    createCommentCalls++;
    if (nextCreateCommentError != null) {
      final Object err = nextCreateCommentError!;
      nextCreateCommentError = null;
      throw err;
    }
    return ForumCreateCommentResponse(
      comment: commentBuilder(parentCommentId, body),
      crisisResources: crisisResourcesOnReply,
    );
  }

  @override
  Future<ForumReport> submitReport({
    required ForumVoteTarget targetKind,
    required String targetId,
    required String reason,
  }) async {
    reportCalls++;
    if (nextReportError != null) {
      final Object err = nextReportError!;
      nextReportError = null;
      throw err;
    }
    return ForumReport(
      id: 'r-1',
      targetKind: targetKind.queryValue,
      targetId: targetId,
      reporterId: 'reporter',
      reason: reason,
      status: 'pending',
      createdAt: _fixedNow,
    );
  }

  @override
  Future<void> deletePost(String postId) async {
    if (nextDeletePostError != null) {
      final Object err = nextDeletePostError!;
      nextDeletePostError = null;
      throw err;
    }
    deletedPostIds.add(postId);
  }

  @override
  Future<void> deleteComment(String commentId) async {
    if (nextDeleteCommentError != null) {
      final Object err = nextDeleteCommentError!;
      nextDeleteCommentError = null;
      throw err;
    }
    deletedCommentIds.add(commentId);
  }
}

ProviderContainer _container(_FakeForumApiClient client) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      forumApiClientProvider.overrideWithValue(client),
    ],
  );
  // PostDetail is autoDispose; a no-op listener keeps the subscription
  // alive for the test so `state =` writes from in-flight futures still
  // land instead of becoming no-ops on a disposed notifier.
  container.listen<PostDetailState>(
    postDetailProvider,
    (PostDetailState? _, PostDetailState __) {},
    fireImmediately: true,
  );
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PostDetailState helpers', () {
    test('replyKey returns the parent id (or empty string for root)', () {
      expect(PostDetailState.replyKey(null), '');
      expect(PostDetailState.replyKey('abc'), 'abc');
    });

    test('voteKey concatenates wire-formatted kind + id', () {
      expect(
        PostDetailState.voteKey(ForumVoteTarget.post, 'xyz'),
        'post:xyz',
      );
      expect(
        PostDetailState.voteKey(ForumVoteTarget.comment, 'abc'),
        'comment:abc',
      );
    });
  });

  group('PostDetail.load — Phase 13.11', () {
    test('loads post + comments from the API', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p', voteCount: 3, commentCount: 2)
        ..commentsToReturn = <ForumComment>[
          _comment('c1', postId: 'p', body: 'first'),
          _comment('c2', postId: 'p', body: 'second'),
        ];
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');

      final PostDetailState state = container.read(postDetailProvider);
      expect(state.postId, 'p');
      expect(state.post?.voteCount, 3);
      expect(state.comments.length, 2);
      expect(state.comments.first.id, 'c1');
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(client.getPostCalls, 1);
      expect(client.listCommentsCalls, 1);
    });

    test('skips the post fetch when initialPost is supplied', () async {
      final ForumPost seeded = _post('p', voteCount: 10);
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..commentsToReturn = <ForumComment>[];
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container
          .read(postDetailProvider.notifier)
          .load('p', initialPost: seeded);

      expect(client.getPostCalls, 0);
      expect(client.listCommentsCalls, 1);
      expect(container.read(postDetailProvider).post, seeded);
    });

    test('captures errors on a failed comments fetch', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p')
        ..nextListCommentsError = Exception('boom');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');

      final PostDetailState state = container.read(postDetailProvider);
      expect(state.isLoading, isFalse);
      expect(state.error, isNotNull);
    });

    test('refresh re-issues the same post + comments fetch', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p', voteCount: 1)
        ..commentsToReturn = <ForumComment>[_comment('c1', postId: 'p')];
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      expect(client.getPostCalls, 1);

      client.postToReturn = _post('p', voteCount: 99);
      await container.read(postDetailProvider.notifier).refresh();
      expect(client.getPostCalls, 2);
      expect(container.read(postDetailProvider).post?.voteCount, 99);
    });
  });

  group('PostDetail.vote — Phase 13.11', () {
    test('optimistically flips the pending arrow then commits the count',
        () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p')
        ..commentsToReturn = <ForumComment>[_comment('c1', voteCount: 2)]
        ..voteResponseFor = (ForumVoteTarget _, String __, int value) =>
            ForumVoteResponse(voteCount: 3, value: value);
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      final Future<void> voteFuture = container
          .read(postDetailProvider.notifier)
          .vote(
            targetKind: ForumVoteTarget.comment,
            targetId: 'c1',
            value: 1,
          );

      // Optimistic flip lands on the microtask queue between the
      // sync arrow update and the awaited API call.
      await Future<void>.value();
      expect(
        container.read(postDetailProvider).pendingVotes[
            PostDetailState.voteKey(ForumVoteTarget.comment, 'c1')],
        1,
      );

      await voteFuture;
      final PostDetailState state = container.read(postDetailProvider);
      expect(state.comments.first.voteCount, 3);
      expect(state.pendingVotes['comment:c1'], 1);
      expect(client.voteCalls, 1);
    });

    test('reverts the pending flip when the cast fails', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p')
        ..commentsToReturn = <ForumComment>[_comment('c1', voteCount: 2)]
        ..nextVoteError = Exception('refused');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      await container.read(postDetailProvider.notifier).vote(
            targetKind: ForumVoteTarget.comment,
            targetId: 'c1',
            value: 1,
          );

      final PostDetailState state = container.read(postDetailProvider);
      expect(state.pendingVotes.containsKey('comment:c1'), isFalse);
      expect(state.comments.first.voteCount, 2);
      expect(state.error, isNotNull);
    });

    test('updates the post vote count on a post-level vote', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p', voteCount: 5)
        ..voteResponseFor = (ForumVoteTarget _, String __, int value) =>
            ForumVoteResponse(voteCount: 6, value: value);
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      await container.read(postDetailProvider.notifier).vote(
            targetKind: ForumVoteTarget.post,
            targetId: 'p',
            value: 1,
          );

      expect(container.read(postDetailProvider).post?.voteCount, 6);
    });
  });

  group('PostDetail.reply — Phase 13.11', () {
    test('appends a successful reply to the local comment list', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p')
        ..commentsToReturn = <ForumComment>[_comment('c1')]
        ..commentBuilder = (String? parent, String body) => _comment(
              'new',
              parent: parent,
              depth: parent == null ? 0 : 1,
              body: body,
            );
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      final ForumCreateCommentResponse? resp = await container
          .read(postDetailProvider.notifier)
          .reply(parentCommentId: 'c1', body: 'thanks');

      expect(resp, isNotNull);
      expect(resp!.comment.id, 'new');
      final PostDetailState state = container.read(postDetailProvider);
      expect(state.comments.length, 2);
      expect(state.comments.last.id, 'new');
      expect(state.postingReplyKeys, isEmpty);
    });

    test('increments the post comment count on a successful reply', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p', commentCount: 3)
        ..commentsToReturn = <ForumComment>[_comment('c1')]
        ..commentBuilder = (String? parent, String body) =>
            _comment('new', parent: parent, body: body);
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      expect(container.read(postDetailProvider).post?.commentCount, 3);

      await container
          .read(postDetailProvider.notifier)
          .reply(body: 'one more');

      // The denormalized count bumps so the header re-renders without a
      // refetch — this is the reply-counter bug the fix targets.
      expect(container.read(postDetailProvider).post?.commentCount, 4);
    });

    test('leaves the comment count untouched on a failed reply', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p', commentCount: 3)
        ..nextCreateCommentError = Exception('429');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      await container.read(postDetailProvider.notifier).reply(body: 'nope');

      expect(container.read(postDetailProvider).post?.commentCount, 3);
    });

    test('returns null and surfaces the error on failed submit', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p')
        ..nextCreateCommentError = Exception('429');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      final ForumCreateCommentResponse? resp = await container
          .read(postDetailProvider.notifier)
          .reply(body: 'oops');

      expect(resp, isNull);
      expect(container.read(postDetailProvider).postingReplyKeys, isEmpty);
      expect(container.read(postDetailProvider).error, isNotNull);
    });
  });

  group('PostDetail.report — Phase 13.11', () {
    test('returns true on a 2xx report', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      final bool ok = await container
          .read(postDetailProvider.notifier)
          .report(
            targetKind: ForumVoteTarget.comment,
            targetId: 'c1',
            reason: 'spam',
          );

      expect(ok, isTrue);
      expect(client.reportCalls, 1);
    });

    test('returns false + records the error when the Worker rejects',
        () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p')
        ..nextReportError = Exception('rate_limited');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      final bool ok = await container
          .read(postDetailProvider.notifier)
          .report(
            targetKind: ForumVoteTarget.comment,
            targetId: 'c1',
            reason: 'spam',
          );

      expect(ok, isFalse);
      expect(container.read(postDetailProvider).error, isNotNull);
    });
  });

  group('PostDetail.deletePost — owner delete', () {
    test('returns true and forwards the id on success', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      final bool ok =
          await container.read(postDetailProvider.notifier).deletePost('p');

      expect(ok, isTrue);
      expect(client.deletedPostIds, <String>['p']);
    });

    test('returns false + records the error when the delete fails', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p')
        ..nextDeletePostError = Exception('forbidden');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      final bool ok =
          await container.read(postDetailProvider.notifier).deletePost('p');

      expect(ok, isFalse);
      expect(client.deletedPostIds, isEmpty);
      expect(container.read(postDetailProvider).error, isNotNull);
    });
  });

  group('PostDetail.deleteComment — owner delete', () {
    test('drops the comment from the list + decrements the post count',
        () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p', commentCount: 2)
        ..commentsToReturn = <ForumComment>[
          _comment('c1', body: 'keep me'),
          _comment('c2', body: 'delete me'),
        ];
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      final bool ok = await container
          .read(postDetailProvider.notifier)
          .deleteComment('c2');

      expect(ok, isTrue);
      expect(client.deletedCommentIds, <String>['c2']);
      final PostDetailState state = container.read(postDetailProvider);
      expect(state.comments.map((ForumComment c) => c.id), <String>['c1']);
      // The denormalized post comment count drops to match.
      expect(state.post?.commentCount, 1);
    });

    test('returns false + keeps the comment when the delete fails', () async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..postToReturn = _post('p', commentCount: 1)
        ..commentsToReturn = <ForumComment>[_comment('c1')]
        ..nextDeleteCommentError = Exception('forbidden');
      final ProviderContainer container = _container(client);
      addTearDown(container.dispose);

      await container.read(postDetailProvider.notifier).load('p');
      final bool ok = await container
          .read(postDetailProvider.notifier)
          .deleteComment('c1');

      expect(ok, isFalse);
      expect(client.deletedCommentIds, isEmpty);
      final PostDetailState state = container.read(postDetailProvider);
      // The row stays put and the count is untouched.
      expect(state.comments.map((ForumComment c) => c.id), <String>['c1']);
      expect(state.post?.commentCount, 1);
      expect(state.error, isNotNull);
    });
  });
}

/// Integration coverage for the Community post detail surface
/// (BUILD_SPEC.md §13 / Phase 13.11 — the post detail pushed from the
/// Community feed, with post + comment voting, inline nested replies, the
/// max-depth reply cap, and the long-press report flow), per TASKS.md
/// Phase 15.12.
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15
/// harness (pinned clock, no-op TTS/analytics) plus a process-local
/// [FakeForumApiClient] wired in as the [forumApiClientProvider] override
/// so the feed, the detail header, the comment tree, the vote round-trips,
/// and the report submissions all read and write the same in-memory store
/// the test asserts against — never goldens.
///
/// The fake seeds its three demo posts; this suite adds comments on the
/// first feed card (hottest post) via the same public `createComment`
/// path the screen uses, so the seeded thread carries real ids the
/// recursive [CommentThread] keys off. Six caregiver flows:
///   1. **Post body + header** — title + derived author + relative time +
///      full body all render on the pushed detail screen.
///   2. **Upvote toggle** — tap upvote → count +1 + arrow highlighted;
///      tap again → count reverts and the highlight clears.
///   3. **Mutual exclusion** — upvote active, then downvote → upvote
///      clears, downvote highlights, count drops by two.
///   4. **Inline reply** — reply on a depth-0 comment → inline composer
///      below the parent → submit → a depth-1 reply lands, indented a
///      step further right than its parent.
///   5. **Max-depth reply hidden** — a 6-level-deep comment exposes no
///      reply button (a deeper reply would 400 server-side).
///   6. **Report flow** — long-press a comment → report sheet → "Off-topic"
///      → a `comment` report with the right target id + reason lands in the
///      fake backend.
library;

import 'package:careblazers/models/forum.dart';
import 'package:careblazers/screens/community/community_feed_screen.dart';
import 'package:careblazers/screens/community/post_compose_screen.dart';
import 'package:careblazers/screens/community/post_detail_screen.dart';
import 'package:careblazers/services/fake_forum_api_client.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/community/comment_thread.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

void main() {
  group('Community post detail — Phase 15.12', () {
    testWidgets('post body + header render on the pushed detail screen',
        (WidgetTester tester) async {
      final _Detail d = await _pumpToFirstPost(tester, seed: _seedTwoNested);

      // The feed tile pushed onto the root navigator — the shell (and the
      // feed card that also held this title) is gone, so each header
      // string is unique.
      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(find.byType(CommunityFeedScreen), findsNothing);

      // Title + full body render verbatim (the detail header does not
      // truncate the body the way the feed card does).
      expect(find.text(d.post.title), findsOneWidget);
      expect(find.text(d.post.body), findsOneWidget);

      // Author display name + relative time share one header line. The
      // hottest seed post is Mei's ("profile-mei"), posted 21h before the
      // pinned clock.
      expect(find.text('Caregiver_mei · 21h ago'), findsOneWidget);

      await _flushTimers(tester);
    });

    testWidgets('upvote toggles the count and the arrow highlight',
        (WidgetTester tester) async {
      final _Detail d = await _pumpToFirstPost(tester, seed: _seedTwoNested);
      final int base = d.post.voteCount; // 27 on the hottest seed post.

      // Neutral to start.
      expect(find.text('$base'), findsOneWidget);
      expect(_upvoteColor(tester), careblazersColors.primarySoft);

      // Upvote → +1, arrow lights up in the brand CTA salmon.
      await tester.tap(find.byKey(PostDetailScreen.postUpvoteKey));
      await tester.pumpAndSettle();
      expect(find.text('${base + 1}'), findsOneWidget);
      expect(_upvoteColor(tester), careblazersColors.cta);

      // Tap again → reverts to the original count, highlight clears.
      await tester.tap(find.byKey(PostDetailScreen.postUpvoteKey));
      await tester.pumpAndSettle();
      expect(find.text('$base'), findsOneWidget);
      expect(_upvoteColor(tester), careblazersColors.primarySoft);

      await _flushTimers(tester);
    });

    testWidgets('upvote then downvote clears the up, highlights the down, -2',
        (WidgetTester tester) async {
      final _Detail d = await _pumpToFirstPost(tester, seed: _seedTwoNested);
      final int base = d.post.voteCount;

      await tester.tap(find.byKey(PostDetailScreen.postUpvoteKey));
      await tester.pumpAndSettle();
      expect(find.text('${base + 1}'), findsOneWidget);
      expect(_upvoteColor(tester), careblazersColors.cta);

      // Flip to downvote: the single per-target vote swings from +1 to -1,
      // so the count drops by two from the upvoted state.
      await tester.tap(find.byKey(PostDetailScreen.postDownvoteKey));
      await tester.pumpAndSettle();

      expect(find.text('${base - 1}'), findsOneWidget); // (base+1) - 2
      expect(_upvoteColor(tester), careblazersColors.primarySoft);
      expect(_downvoteColor(tester), careblazersColors.primary);

      await _flushTimers(tester);
    });

    testWidgets('inline reply on a depth-0 comment lands an indented child',
        (WidgetTester tester) async {
      final _Detail d = await _pumpToFirstPost(tester, seed: _seedTwoNested);
      final ForumComment root = d.comments.first; // depth 0
      const String replyBody = 'Inline reply from the test.';

      // No composer until the reply button is tapped.
      expect(find.byKey(CommentThread.replyComposerKey(root.id)), findsNothing);

      await tester.tap(find.byKey(CommentThread.replyButtonKey(root.id)));
      await tester.pumpAndSettle();

      // Composer inlines below the parent comment.
      final Finder composer = find.byKey(CommentThread.replyComposerKey(root.id));
      expect(composer, findsOneWidget);

      await tester.enterText(
        find.byKey(CommentThread.replyFieldKey(root.id)),
        replyBody,
      );
      await tester.tap(find.byKey(CommentThread.replySendKey(root.id)));
      await tester.pumpAndSettle();

      // The backend stored a depth-1 child of the root comment.
      final ForumComment created = (await d.fake.listComments(postId: d.post.id))
          .firstWhere((ForumComment c) => c.body == replyBody);
      expect(created.parentCommentId, root.id);
      expect(created.depth, 1);

      // It renders in the thread, indented exactly one step further right
      // than its parent row.
      expect(find.text(replyBody), findsOneWidget);
      final double parentLeft =
          tester.getTopLeft(find.byKey(CommentThread.rowKey(root.id))).dx;
      final double childLeft =
          tester.getTopLeft(find.byKey(CommentThread.rowKey(created.id))).dx;
      expect(childLeft - parentLeft, closeTo(commentIndentStep, 0.5));

      await _flushTimers(tester);
    });

    testWidgets('a max-depth comment exposes no reply button',
        (WidgetTester tester) async {
      final _Detail d = await _pumpToFirstPost(tester, seed: _seedDeepChain);
      final ForumComment shallow = d.comments.first; // depth 0
      final ForumComment deepest = d.comments.last; // depth == maxCommentDepth

      expect(deepest.depth, maxCommentDepth);
      // The deepest row is still rendered…
      expect(find.byKey(CommentThread.rowKey(deepest.id)), findsOneWidget);
      // …but its reply affordance is gone (a deeper reply would 400).
      expect(
        find.byKey(CommentThread.replyButtonKey(deepest.id)),
        findsNothing,
      );
      // A shallow comment still offers reply, so the cap is depth-driven.
      expect(
        find.byKey(CommentThread.replyButtonKey(shallow.id)),
        findsOneWidget,
      );

      await _flushTimers(tester);
    });

    testWidgets('long-press → report → Off-topic files a comment report',
        (WidgetTester tester) async {
      // The report flow is for OTHER people's comments. The fake seeds its
      // comments as the demo profile, so report against a backend whose
      // "me" profile is someone else — then the seeded comments read as
      // foreign and surface the report flag (not the owner delete sheet).
      final _Detail d = await _pumpToFirstPost(
        tester,
        seed: _seedTwoNested,
        client: _NotMyContentFake(clock: () => kHarnessClock),
      );
      final ForumComment target = d.comments.first;

      await tester.longPress(find.byKey(CommentThread.rowKey(target.id)));
      await tester.pumpAndSettle();
      expect(find.text('Report this comment'), findsOneWidget);

      await tester.tap(find.byKey(const Key('report-reason-off_topic')));
      await tester.pumpAndSettle();

      // A pending report landed in the fake backend with the comment as
      // its target and the chosen reason.
      final List<ForumReport> reports = await d.fake.listReports();
      expect(reports, hasLength(1));
      final ForumReport report = reports.single;
      expect(report.targetKind, ForumVoteTarget.comment.queryValue);
      expect(report.targetId, target.id);
      expect(report.reason, 'off_topic');

      await _flushTimers(tester);
    });
  });

  group('Community post detail — owner edit/delete', () {
    testWidgets(
      "another caregiver's post shows the report flag, not the owner menu",
      (WidgetTester tester) async {
        // The hottest seed post is Mei's — NOT the demo user's. The owner
        // menu must be absent; the report flag present.
        await _pumpToFirstPost(tester, seed: _seedTwoNested);

        expect(find.byKey(PostDetailScreen.postOwnerMenuKey), findsNothing);
        expect(find.byKey(PostDetailScreen.postReportKey), findsOneWidget);

        await _flushTimers(tester);
      },
    );

    testWidgets('editing my own post updates its body via updatePost',
        (WidgetTester tester) async {
      final _OwnPost own = await _pumpToOwnPost(tester);
      const String newBody = 'Edited body — the walk worked the second night.';

      // The owner menu is present on my own post; the report flag is not.
      expect(find.byKey(PostDetailScreen.postOwnerMenuKey), findsOneWidget);
      expect(find.byKey(PostDetailScreen.postReportKey), findsNothing);

      await tester.tap(find.byKey(PostDetailScreen.postOwnerMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PostDetailScreen.postEditKey));
      await tester.pumpAndSettle();

      // The compose screen opened in edit mode, prefilled with the post.
      expect(find.byType(PostComposeScreen), findsOneWidget);
      expect(find.text('Edit post'), findsWidgets);
      final TextField bodyField = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(PostComposeScreen.bodyFieldKey),
          matching: find.byType(TextField),
        ),
      );
      expect(bodyField.controller?.text, own.post.body);

      // Replace the body and save.
      await tester.enterText(
        find.byKey(PostComposeScreen.bodyFieldKey),
        newBody,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PostComposeScreen.submitButtonKey));
      await tester.pumpAndSettle();

      // The backend body changed; the title did not (the Worker only
      // updates the body).
      final ForumPost stored = await own.fake.getPost(own.post.id);
      expect(stored.body, newBody);
      expect(stored.title, own.post.title);

      // Back on the detail screen, the edited body renders.
      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(find.text(newBody), findsOneWidget);

      await _flushTimers(tester);
    });

    testWidgets('deleting my own post removes it and pops to the feed',
        (WidgetTester tester) async {
      final _OwnPost own = await _pumpToOwnPost(tester);

      await tester.tap(find.byKey(PostDetailScreen.postOwnerMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PostDetailScreen.postDeleteKey));
      await tester.pumpAndSettle();

      // Confirm the destructive action.
      expect(find.text('Delete this post?'), findsOneWidget);
      await tester.tap(find.byKey(PostDetailScreen.postDeleteConfirmKey));
      await tester.pumpAndSettle();

      // The post is gone from the backend and we're back on the feed.
      expect(
        (await own.fake.listPosts(sort: ForumPostSort.newest))
            .where((ForumPost p) => p.id == own.post.id),
        isEmpty,
      );
      expect(find.byType(PostDetailScreen), findsNothing);
      expect(find.byType(CommunityFeedScreen), findsOneWidget);

      await _flushTimers(tester);
    });

    testWidgets('deleting my own comment removes it from the thread',
        (WidgetTester tester) async {
      final _OwnPost own = await _pumpToOwnPost(tester);
      // The seeded comment on my own post is mine too (createComment stamps
      // the demo profile), so it carries the owner delete affordance.
      final ForumComment mine = own.comment;

      // No report flag on my own comment; a delete trigger instead.
      expect(
        find.byKey(CommentThread.deleteTriggerKey(mine.id)),
        findsOneWidget,
      );

      await tester.longPress(find.byKey(CommentThread.rowKey(mine.id)));
      await tester.pumpAndSettle();
      expect(find.text('Your reply'), findsOneWidget);

      await tester.tap(find.byKey(CommentThread.deleteKey(mine.id)));
      await tester.pumpAndSettle();

      // Gone from the backend and from the rendered thread.
      final List<ForumComment> remaining =
          await own.fake.listComments(postId: own.post.id);
      expect(remaining.where((ForumComment c) => c.id == mine.id), isEmpty);
      expect(find.byKey(CommentThread.rowKey(mine.id)), findsNothing);

      await _flushTimers(tester);
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Everything a flow asserts against once the detail screen is open: the
/// process-local fake backend, the post that was tapped, and the comments
/// seeded onto it (in creation order, so `.first` is the depth-0 root and
/// `.last` is the deepest leaf).
class _Detail {
  _Detail(this.fake, this.post, this.comments);

  final FakeForumApiClient fake;
  final ForumPost post;
  final List<ForumComment> comments;
}

/// Seeder signature: add comments to [postId] on [fake] before the app
/// pumps and return them in creation order.
typedef _CommentSeeder = Future<List<ForumComment>> Function(
  FakeForumApiClient fake,
  String postId,
);

/// Stand up a [FakeForumApiClient] on the pinned harness clock, seed
/// comments on the hottest post (the first feed card), pump the real app
/// over it, then navigate Community tab → first post card → the pushed
/// [PostDetailScreen]. Both forum clocks are pinned so relative-time
/// strings stay deterministic.
Future<_Detail> _pumpToFirstPost(
  WidgetTester tester, {
  required _CommentSeeder seed,
  FakeForumApiClient? client,
}) async {
  final FakeForumApiClient fake =
      client ?? FakeForumApiClient(clock: () => kHarnessClock);
  // Hot sort matches the feed's default, so the first listed post is the
  // first card the caregiver taps.
  final ForumPost first = (await fake.listPosts()).first;
  final List<ForumComment> comments = await seed(fake, first.id);

  await pumpCareblazersApp(
    tester,
    extraOverrides: <Override>[
      forumApiClientProvider.overrideWithValue(fake),
      postDetailClockProvider.overrideWithValue(() => kHarnessClock),
      communityFeedClockProvider.overrideWithValue(() => kHarnessClock),
    ],
  );

  // Widen past the harness default so the post header's vote/reply/report
  // action row lays out without overflowing (the harness teardown resets
  // the surface to null).
  await tester.binding.setSurfaceSize(const Size(600, 1400));
  await tester.pumpAndSettle();

  await tester.tap(tabFor('Community'));
  await tester.pumpAndSettle();
  expect(find.byType(CommunityFeedScreen), findsOneWidget);

  await tester.tap(find.byKey(CommunityFeedScreen.postTileKey(first.id)));
  await tester.pumpAndSettle();
  expect(find.byType(PostDetailScreen), findsOneWidget);

  return _Detail(fake, first, comments);
}

/// Everything an owner-flow asserts against once the detail screen for the
/// caregiver's OWN post is open: the fake backend, the post the demo user
/// authored, and the (also demo-authored) comment seeded on it.
class _OwnPost {
  _OwnPost(this.fake, this.post, this.comment);

  final FakeForumApiClient fake;
  final ForumPost post;
  final ForumComment comment;
}

/// Stand up the fake, create a post AS the demo caregiver (so its
/// `author_id` is the demo profile → owned), seed one of their own comments
/// on it, pump the app, then navigate Community → New sort (the fresh post,
/// created at the pinned now, sorts first) → its detail screen. Returns the
/// owned post + comment so the owner-flow tests can assert against them.
Future<_OwnPost> _pumpToOwnPost(WidgetTester tester) async {
  final FakeForumApiClient fake =
      FakeForumApiClient(clock: () => kHarnessClock);
  // createPost stamps author_id with the demo profile id — this is "my" post.
  final ForumPost mine = (await fake.createPost(
    title: 'First night alone with Dad',
    body: 'He kept asking where Mom was. A walk reset him. Sharing in case.',
  ))
      .post;
  // A comment I authored on my own post (createComment also stamps the demo
  // profile), so it carries the owner delete affordance.
  final ForumComment myComment = (await fake.createComment(
    postId: mine.id,
    body: 'Following up: night two went smoother.',
  ))
      .comment;

  await pumpCareblazersApp(
    tester,
    extraOverrides: <Override>[
      forumApiClientProvider.overrideWithValue(fake),
      postDetailClockProvider.overrideWithValue(() => kHarnessClock),
      communityFeedClockProvider.overrideWithValue(() => kHarnessClock),
    ],
  );

  await tester.binding.setSurfaceSize(const Size(600, 1400));
  await tester.pumpAndSettle();

  await tester.tap(tabFor('Community'));
  await tester.pumpAndSettle();
  expect(find.byType(CommunityFeedScreen), findsOneWidget);

  // Switch to New so my just-created post (createdAt == the pinned now) sorts
  // to the top of the feed, where its tile is on-screen to tap.
  await tester.tap(find.byKey(CommunityFeedScreen.sortNewKey));
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(CommunityFeedScreen.postTileKey(mine.id)));
  await tester.pumpAndSettle();
  expect(find.byType(PostDetailScreen), findsOneWidget);

  return _OwnPost(fake, mine, myComment);
}

/// A [FakeForumApiClient] whose `GET /profiles/me` resolves to a profile id
/// that does NOT match the one the fake stamps onto seeded content. From the
/// app's perspective every seeded post + comment then reads as *someone
/// else's*, so the report affordances (rather than the owner edit/delete
/// ones) surface — the right backing for the report flow, which only applies
/// to other people's content.
class _NotMyContentFake extends FakeForumApiClient {
  _NotMyContentFake({super.clock});

  @override
  Future<ForumProfile> getMyProfile() async => ForumProfile(
        id: 'profile-not-mine',
        careblazersUserId: 'cb-not-mine',
        displayName: 'Lurker',
        joinedAt: kHarnessClock.subtract(const Duration(days: 1)),
        role: 'user',
      );

  @override
  Future<ForumProfile> bootstrapProfile() async => getMyProfile();
}

/// Two nested comments on [postId]: a depth-0 root plus a depth-1 reply to
/// it (TASKS.md Phase 15.12 base fixture).
Future<List<ForumComment>> _seedTwoNested(
  FakeForumApiClient fake,
  String postId,
) async {
  final ForumComment root = (await fake.createComment(
    postId: postId,
    body: 'Root comment — thank you for sharing this.',
  ))
      .comment;
  final ForumComment reply = (await fake.createComment(
    postId: postId,
    body: 'Nested reply — this helped me too.',
    parentCommentId: root.id,
  ))
      .comment;
  return <ForumComment>[root, reply];
}

/// A single chain of comments from depth 0 down to [maxCommentDepth], each
/// replying to the one above it — the deepest leaf sits at the reply cap.
Future<List<ForumComment>> _seedDeepChain(
  FakeForumApiClient fake,
  String postId,
) async {
  final List<ForumComment> chain = <ForumComment>[];
  String? parentId;
  for (int depth = 0; depth <= maxCommentDepth; depth++) {
    final ForumComment c = (await fake.createComment(
      postId: postId,
      body: 'Depth $depth comment.',
      parentCommentId: parentId,
    ))
        .comment;
    chain.add(c);
    parentId = c.id;
  }
  return chain;
}

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------

Color? _upvoteColor(WidgetTester tester) =>
    tester.widget<IconButton>(find.byKey(PostDetailScreen.postUpvoteKey)).color;

Color? _downvoteColor(WidgetTester tester) => tester
    .widget<IconButton>(find.byKey(PostDetailScreen.postDownvoteKey))
    .color;

/// Drain the still-mounted bare timers (the report SnackBar's auto-dismiss
/// + any quiet-hours tick) so none outlive the test and trip
/// flutter_test's "Timer still pending" invariant — mirrors the Phase 15.9
/// flow's flush.
Future<void> _flushTimers(WidgetTester tester) async {
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

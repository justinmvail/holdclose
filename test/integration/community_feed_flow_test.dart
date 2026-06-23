/// Integration coverage for the Community feed flow (BUILD_SPEC.md §5.16
/// + §13 — the social Feed at `/community`, its Hot/New/Top sort selector,
/// pull-to-refresh, the compose FAB → [PostComposeScreen] round-trip, and
/// the admin-only moderation entry → [AdminReportsScreen]), per TASKS.md
/// Phase 15.13. Companion to the Phase 15.12 post-detail flow
/// ([community_post_flow_test.dart]).
///
/// These drive the *real* [HoldcloseApp] over the shared Phase 15
/// harness (pinned clock, no-op TTS/analytics) plus a process-local
/// [FakeForumApiClient] wired in as the [forumApiClientProvider] override
/// so the feed, the sort re-fetches, the refresh round-trip, the new post,
/// and the moderation queue all read and write the same in-memory store
/// the test asserts against — never goldens.
///
/// The fake seeds its three demo posts (Sarah 12 votes / 5h, Mei 27 votes
/// / 21h, Rob 8 votes / 48h), which gives every sort key a distinct,
/// deterministic order:
///   * **Hot / Top** — votes desc → Mei, Sarah, Rob (`2, 1, 3`).
///   * **New** — createdAt desc → Sarah, Mei, Rob (`1, 2, 3`).
///
/// Note on "staff role": forum admin status is sourced from the signed-in
/// caregiver's [ForumProfile.role] (via [isForumAdminProvider]), NOT from
/// the OAuth identity the harness's [FakeAuthProvider] carries — that
/// provider has no role concept. So "flip to staff role" is modeled by an
/// admin-profile fake backend, matching `community_feed_admin_action_test`.
///
/// Four caregiver flows:
///   1. **Sort switching** — Hot/New/Top selector re-fetches the feed in
///      the deterministic order the fake returns for each key.
///   2. **Pull-to-refresh** — dragging the list down surfaces the refresh
///      spinner mid-pull and re-fetches page one from the backend.
///   3. **Compose FAB** — tap → [PostComposeScreen] → fill title + body →
///      Post → back on the feed with the new post atop the New sort.
///   4. **Admin moderation entry** — a non-staff caregiver never sees the
///      moderation action; flipping to a staff profile and re-pumping
///      surfaces it, and tapping opens [AdminReportsScreen] listing the
///      seeded pending reports.
library;

import 'package:holdclose/models/forum.dart';
import 'package:holdclose/providers/community_feed_provider.dart';
import 'package:holdclose/providers/guidelines_acknowledged_provider.dart';
import 'package:holdclose/providers/my_forum_profile_provider.dart'
    show forumAdminRole;
import 'package:holdclose/screens/community/admin_reports_screen.dart';
import 'package:holdclose/screens/community/community_feed_screen.dart';
import 'package:holdclose/screens/community/post_compose_screen.dart';
import 'package:holdclose/services/fake_forum_api_client.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

void main() {
  group('Community feed — Phase 15.13', () {
    testWidgets('Hot/New/Top selector re-fetches in the deterministic order',
        (WidgetTester tester) async {
      final FakeForumApiClient fake =
          FakeForumApiClient(clock: () => kHarnessClock);
      final ProviderContainer container = await _pumpCommunity(tester, fake);

      // The feed lands on the default Hot sort: votes desc → Mei, Sarah, Rob.
      expect(container.read(communityFeedProvider).sort, ForumPostSort.hot);
      expect(_feedIds(container),
          <String>['seed-post-2', 'seed-post-1', 'seed-post-3']);

      // New → createdAt desc → Sarah (5h), Mei (21h), Rob (48h).
      await tester.tap(find.byKey(CommunityFeedScreen.sortNewKey));
      await tester.pumpAndSettle();
      expect(container.read(communityFeedProvider).sort, ForumPostSort.newest);
      expect(_feedIds(container),
          <String>['seed-post-1', 'seed-post-2', 'seed-post-3']);
      // The list itself re-rendered in that order, not just the provider.
      expect(_tileTop(tester, 'seed-post-1'),
          lessThan(_tileTop(tester, 'seed-post-2')));
      expect(_tileTop(tester, 'seed-post-2'),
          lessThan(_tileTop(tester, 'seed-post-3')));

      // Top → votes desc → Mei, Sarah, Rob again.
      await tester.tap(find.byKey(CommunityFeedScreen.sortTopKey));
      await tester.pumpAndSettle();
      expect(container.read(communityFeedProvider).sort, ForumPostSort.top);
      expect(_feedIds(container),
          <String>['seed-post-2', 'seed-post-1', 'seed-post-3']);

      // Back to Hot.
      await tester.tap(find.byKey(CommunityFeedScreen.sortHotKey));
      await tester.pumpAndSettle();
      expect(container.read(communityFeedProvider).sort, ForumPostSort.hot);
      expect(_feedIds(container),
          <String>['seed-post-2', 'seed-post-1', 'seed-post-3']);

      await _flushTimers(tester);
    });

    testWidgets('pull-to-refresh surfaces the spinner and re-fetches',
        (WidgetTester tester) async {
      final _CountingFakeForumApiClient fake =
          _CountingFakeForumApiClient(clock: () => kHarnessClock);
      await _pumpCommunity(tester, fake);

      // The initial feed load already fired one listPosts; capture it as the
      // baseline so the assertion proves the *pull* triggered a fresh fetch.
      final int baseline = fake.listPostsCalls;
      expect(baseline, greaterThanOrEqualTo(1));

      // Drag the list down from the top — RefreshIndicator arms its spinner
      // mid-pull before the onRefresh future settles.
      await tester.fling(
        find.byKey(CommunityFeedScreen.listKey),
        const Offset(0, 320),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();

      // The spinner retracted and the refresh re-hit the backend.
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(fake.listPostsCalls, greaterThan(baseline));

      await _flushTimers(tester);
    });

    testWidgets('compose FAB posts a new entry that tops the New sort',
        (WidgetTester tester) async {
      final FakeForumApiClient fake =
          FakeForumApiClient(clock: () => kHarnessClock);
      // Skip the first-post acknowledgement modal so the flow stays focused
      // on compose → post → feed (the ack sheet has its own widget test).
      final ProviderContainer container = await _pumpCommunity(
        tester,
        fake,
        extraOverrides: <Override>[
          guidelinesAcknowledgedProvider.overrideWith(_Acknowledged.new),
        ],
      );

      // Open the compose surface from the feed-scoped FAB.
      await tester.tap(find.byKey(CommunityFeedScreen.composeFabKey));
      await tester.pumpAndSettle();
      expect(find.byType(PostComposeScreen), findsOneWidget);

      const String title = 'First night alone with Dad';
      const String body =
          "He kept asking where Mom was. A walk around the block reset him.";
      await tester.enterText(
          find.byKey(PostComposeScreen.titleFieldKey), title);
      await tester.enterText(find.byKey(PostComposeScreen.bodyFieldKey), body);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(PostComposeScreen.submitButtonKey));
      await tester.pumpAndSettle();

      // Back on the feed.
      expect(find.byType(PostComposeScreen), findsNothing);
      expect(find.byType(CommunityFeedScreen), findsOneWidget);

      // The post landed in the backend.
      final ForumPost newest =
          (await fake.listPosts(sort: ForumPostSort.newest)).first;
      expect(newest.title, title);

      // And it sits atop the New sort (its createdAt == the pinned now, so
      // it out-ranks every seeded post).
      await tester.tap(find.byKey(CommunityFeedScreen.sortNewKey));
      await tester.pumpAndSettle();
      final CommunityFeedState feed = container.read(communityFeedProvider);
      expect(feed.sort, ForumPostSort.newest);
      expect(feed.posts.first.title, title);
      expect(feed.posts.first.id, newest.id);
      expect(find.text(title), findsWidgets);

      await _flushTimers(tester);
    });

    testWidgets('staff role reveals the moderation entry → seeded reports',
        (WidgetTester tester) async {
      // A non-staff caregiver never sees the moderation action.
      final FakeForumApiClient user =
          FakeForumApiClient(clock: () => kHarnessClock);
      await _pumpCommunity(tester, user);
      expect(find.byKey(CommunityFeedScreen.adminActionKey), findsNothing);

      // Flip to a staff profile, seed two pending reports, and re-pump.
      final _AdminFakeForumApiClient admin =
          _AdminFakeForumApiClient(clock: () => kHarnessClock);
      final ForumReport postReport = await admin.submitReport(
        targetKind: ForumVoteTarget.post,
        targetId: 'seed-post-1',
        reason: 'spam',
      );
      final ForumReport commentReport = await admin.submitReport(
        targetKind: ForumVoteTarget.comment,
        targetId: 'seed-comment-7',
        reason: 'harassment',
      );
      await _pumpCommunity(tester, admin);

      // The shield action now shows on the Feed segment.
      final Finder adminAction =
          find.byKey(CommunityFeedScreen.adminActionKey);
      expect(adminAction, findsOneWidget);

      await tester.tap(adminAction);
      await tester.pumpAndSettle();

      // The moderation queue lists every seeded pending report.
      expect(find.byType(AdminReportsScreen), findsOneWidget);
      expect(find.byKey(AdminReportsScreen.listKey), findsOneWidget);
      expect(
        find.byKey(AdminReportsScreen.reportRowKey(postReport.id)),
        findsOneWidget,
      );
      expect(
        find.byKey(AdminReportsScreen.reportRowKey(commentReport.id)),
        findsOneWidget,
      );

      await _flushTimers(tester);
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Pump the real app over [client] (wired as the [forumApiClientProvider]
/// override on the pinned harness clock), widen past the harness default so
/// the three feed cards lay out without overflow, and navigate the
/// Community tab to its Feed landing. Returns the live container so a flow
/// can read [communityFeedProvider] directly.
Future<ProviderContainer> _pumpCommunity(
  WidgetTester tester,
  ForumApiClient client, {
  List<Override> extraOverrides = const <Override>[],
}) async {
  final ProviderContainer container = await pumpHoldcloseApp(
    tester,
    extraOverrides: <Override>[
      forumApiClientProvider.overrideWithValue(client),
      communityFeedClockProvider.overrideWithValue(() => kHarnessClock),
      ...extraOverrides,
    ],
  );

  await tester.binding.setSurfaceSize(const Size(600, 1400));
  await tester.pumpAndSettle();

  await tester.tap(tabFor('Community'));
  await tester.pumpAndSettle();
  expect(find.byType(CommunityFeedScreen), findsOneWidget);

  return container;
}

/// The current feed post ids, in render order — the deterministic signal a
/// sort re-fetch lands the page the fake returns for that key.
List<String> _feedIds(ProviderContainer container) => container
    .read(communityFeedProvider)
    .posts
    .map((ForumPost p) => p.id)
    .toList(growable: false);

/// The vertical offset of the post tile keyed by [postId], for asserting
/// the rendered list order (not just the provider state).
double _tileTop(WidgetTester tester, String postId) =>
    tester.getTopLeft(find.byKey(CommunityFeedScreen.postTileKey(postId))).dy;

/// [FakeForumApiClient] that counts how many times the feed asked it for a
/// page, so the pull-to-refresh flow can prove the drag re-fetched.
class _CountingFakeForumApiClient extends FakeForumApiClient {
  _CountingFakeForumApiClient({super.clock});

  int listPostsCalls = 0;

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) {
    listPostsCalls++;
    return super.listPosts(sort: sort, before: before, limit: limit);
  }
}

/// [FakeForumApiClient] whose signed-in profile carries the `admin` role,
/// so [isForumAdminProvider] resolves true and the moderation surfaces
/// unlock. Models the "staff role" the spec flips to (forum admin status
/// lives in the [ForumProfile], not the OAuth identity).
class _AdminFakeForumApiClient extends FakeForumApiClient {
  _AdminFakeForumApiClient({super.clock});

  ForumProfile _adminProfile() => ForumProfile(
        id: 'demo-profile',
        careblazersUserId: 'demo-user',
        displayName: 'You',
        joinedAt: kHarnessClock.subtract(const Duration(days: 60)),
        role: forumAdminRole,
      );

  @override
  Future<ForumProfile> getMyProfile() async => _adminProfile();

  @override
  Future<ForumProfile> bootstrapProfile() async => _adminProfile();
}

/// `GuidelinesAcknowledged` override that reports the community guidelines
/// as already read, so the compose flow skips the first-post modal.
class _Acknowledged extends GuidelinesAcknowledged {
  @override
  Future<bool> build() async => true;
}

/// Drain the still-mounted bare timers (the compose "Posted." SnackBar
/// auto-dismiss, Home's catch-me-up recap, any quiet-hours tick) so none
/// outlive the test and trip flutter_test's "Timer still pending"
/// invariant — mirrors the Phase 15.12 flow's flush.
Future<void> _flushTimers(WidgetTester tester) async {
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

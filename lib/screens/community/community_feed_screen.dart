import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/forum.dart';
import '../../providers/community_feed_provider.dart';
import '../../providers/community_subnav_provider.dart';
import '../../providers/my_forum_profile_provider.dart';
import '../../routing/router.dart' show CareblazersRoutes;
import '../../services/forum_api_client.dart';
import '../../theme.dart';
import '../../widgets/segmented_subnav.dart';
import 'learn_screen.dart';

part 'community_feed_screen.g.dart';

/// Wall clock the community feed uses when rendering relative timestamps
/// ("5m ago", "2h ago"). Overridable so widget + golden tests can pin a
/// fixed reference time and the rendered strings stay deterministic
/// regardless of the host clock.
@Riverpod(keepAlive: true)
DateTime Function() communityFeedClock(Ref ref) => DateTime.now;

/// Pixels-from-bottom that trigger the next-page fetch. 240 — roughly
/// two tile heights — keeps the next page in flight before the
/// caregiver's thumb reaches the spinner footer.
const double _loadMoreTriggerPx = 240;

/// The three in-tab views surfaced by the Community sub-nav
/// (Phase 14.36, `docs/MENU_LAYOUT_SPEC.md` §5). The segment swap is
/// in-tab and does NOT change the URL — the sub-nav exists precisely so
/// a sixth destination's worth of content can live under `/community`
/// without adding a sixth bottom tab.
enum CommunitySegment {
  /// The social feed of caregiver + official posts (the tab's landing).
  feed,

  /// The Careblazers content library — videos + playbooks (Phase 14.37
  /// lands the real `LearnScreen` here).
  learn,

  /// Caregiver wellbeing tools — burnout self-check, respite, expert
  /// Q&A (Phase 14.38 lands the real `SupportScreen` here).
  support,
}

/// Community landing at `/community` (BUILD_SPEC.md §13 / Phase 13.10),
/// fronted by the Feed/Learn/Support in-tab sub-nav (Phase 14.36).
///
/// Layout:
///   * AppBar: title "Community".
///   * [SegmentedSubnav] directly below the title — Feed · Learn ·
///     Support. Swapping a segment is in-tab and leaves the URL on
///     `/community` (per `docs/MENU_LAYOUT_SPEC.md`: the in-tab sub-nav
///     avoids a 6th tab). The active segment is held in local widget
///     state so a push into a post detail and back preserves it;
///     re-selecting the Community bottom-tab snaps back to Feed via
///     [CommunityTabReentry].
///   * **Feed segment** — sort selector (Hot / New / Top) over a
///     pull-to-refresh list of post cards. Each card carries title, a
///     derived author display name + initial-letter avatar, relative
///     time, a 3-line body preview, and the vote + comment counts.
///     Empty state: "Be the first to post." Loading: a soft skeleton.
///   * **Learn / Support segments** — owned by Phases 14.37 / 14.38;
///     rendered here as soft placeholders until those screens land.
///
/// The compose FAB and the moderation action are feed-scoped — they
/// only show while the Feed segment is active.
class CommunityFeedScreen extends ConsumerStatefulWidget {
  const CommunityFeedScreen({super.key});

  static const Key sortHotKey = Key('community-feed-sort-hot');
  static const Key sortNewKey = Key('community-feed-sort-new');
  static const Key sortTopKey = Key('community-feed-sort-top');
  static const Key listKey = Key('community-feed-list');
  static const Key emptyStateKey = Key('community-feed-empty');
  static const Key loadingKey = Key('community-feed-loading');
  static const Key errorKey = Key('community-feed-error');
  static const Key loadMoreSpinnerKey = Key('community-feed-load-more-spinner');
  static const Key composeFabKey = Key('community-feed-compose-fab');
  static const Key adminActionKey = Key('community-feed-admin-action');

  /// The Feed/Learn/Support sub-nav (Phase 14.36).
  static const Key subnavKey = Key('community-subnav');

  /// Body wrappers for the two not-yet-built segments, so tests can
  /// assert the swap without depending on the placeholder copy.
  static const Key learnSegmentKey = Key('community-learn-segment');
  static const Key supportSegmentKey = Key('community-support-segment');

  static Key postTileKey(String postId) => Key('community-feed-tile-$postId');

  @override
  ConsumerState<CommunityFeedScreen> createState() =>
      _CommunityFeedScreenState();
}

class _CommunityFeedScreenState extends ConsumerState<CommunityFeedScreen> {
  final ScrollController _scrollController = ScrollController();

  /// The active in-tab segment. Local state (not a provider) so a push
  /// into a post detail and back preserves it — only a Community
  /// bottom-tab selection resets it (see the [CommunityTabReentry]
  /// listener in [build]).
  CommunitySegment _segment = CommunitySegment.feed;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    final double offset = _scrollController.position.pixels;
    final double max = _scrollController.position.maxScrollExtent;
    if (max - offset > _loadMoreTriggerPx) return;
    // Defer to a post-frame callback so we don't fire setState/state
    // changes while Flutter is already in the middle of a layout pass.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(communityFeedProvider.notifier).loadMore());
    });
  }

  /// Map the active segment onto its sub-nav index for [SegmentedSubnav].
  static const List<CommunitySegment> _segmentOrder = <CommunitySegment>[
    CommunitySegment.feed,
    CommunitySegment.learn,
    CommunitySegment.support,
  ];

  @override
  Widget build(BuildContext context) {
    final CommunityFeedState feed = ref.watch(communityFeedProvider);
    final DateTime now = ref.watch(communityFeedClockProvider)();
    final bool isAdmin = ref.watch(isForumAdminProvider);

    // A Community bottom-tab selection (switch-from-another-tab or
    // active-tab re-tap) bumps the re-entry counter — snap back to the
    // Feed segment, the tab's landing. A push into a post detail and
    // back never bumps it, so the segment survives that round-trip.
    ref.listen<int>(communityTabReentryProvider, (int? _, int __) {
      if (_segment != CommunitySegment.feed) {
        setState(() => _segment = CommunitySegment.feed);
      }
    });

    final bool onFeed = _segment == CommunitySegment.feed;
    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text('Community'),
        automaticallyImplyLeading: false,
        actions: <Widget>[
          // Moderation is a feed concern — only surface it on the Feed
          // segment.
          if (isAdmin && onFeed)
            IconButton(
              key: CommunityFeedScreen.adminActionKey,
              tooltip: 'Moderation queue',
              icon: const Icon(Icons.shield_outlined),
              onPressed: () => context
                  .pushNamed(CareblazersRoutes.communityAdminReports),
            ),
        ],
      ),
      // The compose surface posts to the feed, so it only belongs on the
      // Feed segment.
      floatingActionButton: onFeed
          ? FloatingActionButton.extended(
              key: CommunityFeedScreen.composeFabKey,
              backgroundColor: careblazersColors.cta,
              foregroundColor: Colors.white,
              onPressed: () =>
                  context.pushNamed(CareblazersRoutes.communityCompose),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('New post'),
            )
          : null,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SegmentedSubnav(
                key: CommunityFeedScreen.subnavKey,
                activeIndex: _segmentOrder.indexOf(_segment),
                items: const <SegmentedSubnavItem>[
                  SegmentedSubnavItem(label: 'Feed', key: 'feed'),
                  SegmentedSubnavItem(label: 'Learn', key: 'learn'),
                  SegmentedSubnavItem(label: 'Support', key: 'support'),
                ],
                onChanged: (int index) {
                  final CommunitySegment next = _segmentOrder[index];
                  if (next != _segment) {
                    setState(() => _segment = next);
                  }
                },
              ),
            ),
            Expanded(child: _segmentBody(feed, now)),
          ],
        ),
      ),
    );
  }

  /// The body for the active segment. Feed renders the live post list;
  /// Learn / Support render soft placeholders until Phases 14.37 / 14.38
  /// land the real `LearnScreen` / `SupportScreen`.
  Widget _segmentBody(CommunityFeedState feed, DateTime now) {
    switch (_segment) {
      case CommunitySegment.feed:
        return Column(
          children: <Widget>[
            _SortSelector(
              sort: feed.sort,
              onSelected: (ForumPostSort next) =>
                  ref.read(communityFeedProvider.notifier).setSort(next),
            ),
            Expanded(
              child: _Body(
                feed: feed,
                now: now,
                scrollController: _scrollController,
                onRefresh: () =>
                    ref.read(communityFeedProvider.notifier).refresh(),
              ),
            ),
          ],
        );
      case CommunitySegment.learn:
        // The Careblazers content library — videos + playbooks (Phase
        // 14.37). Keyed with [learnSegmentKey] so the sub-nav swap tests
        // still find the Learn body.
        return const LearnScreen(key: CommunityFeedScreen.learnSegmentKey);
      case CommunitySegment.support:
        return const _SegmentPlaceholder(
          key: CommunityFeedScreen.supportSegmentKey,
          icon: Icons.favorite_outline,
          title: 'Support is on the way',
          body: 'A burnout self-check, respite resources, and expert '
              'answers will live here.',
        );
    }
  }
}

class _SortSelector extends StatelessWidget {
  const _SortSelector({required this.sort, required this.onSelected});

  final ForumPostSort sort;
  final ValueChanged<ForumPostSort> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: <Widget>[
          _SortChip(
            chipKey: CommunityFeedScreen.sortHotKey,
            label: 'Hot',
            selected: sort == ForumPostSort.hot,
            onTap: () => onSelected(ForumPostSort.hot),
          ),
          const SizedBox(width: 8),
          _SortChip(
            chipKey: CommunityFeedScreen.sortNewKey,
            label: 'New',
            selected: sort == ForumPostSort.newest,
            onTap: () => onSelected(ForumPostSort.newest),
          ),
          const SizedBox(width: 8),
          _SortChip(
            chipKey: CommunityFeedScreen.sortTopKey,
            label: 'Top',
            selected: sort == ForumPostSort.top,
            onTap: () => onSelected(ForumPostSort.top),
          ),
        ],
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.chipKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key chipKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label sort. Double-tap to '
          '${selected ? 'reload this view' : 'switch the feed to $label'}.',
      child: Material(
        color: selected
            ? careblazersColors.primary
            : careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          key: chipKey,
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Text(
              label,
              style: textTheme.labelLarge?.copyWith(
                color: selected
                    ? careblazersColors.background
                    : careblazersColors.primarySoft,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.feed,
    required this.now,
    required this.scrollController,
    required this.onRefresh,
  });

  final CommunityFeedState feed;
  final DateTime now;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    // Initial load — show a soft placeholder rather than the empty
    // state. A blank list under a slow first fetch would otherwise
    // flash "Be the first to post" before the real posts arrive.
    if (feed.isLoading && feed.posts.isEmpty) {
      return const _LoadingPlaceholder();
    }
    if (feed.posts.isEmpty && feed.error != null) {
      return _ErrorView(
        message: feed.error.toString(),
        onRetry: onRefresh,
      );
    }
    if (feed.posts.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        color: careblazersColors.cta,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const <Widget>[
            SizedBox(height: 120),
            _EmptyState(),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: careblazersColors.cta,
      child: ListView.separated(
        key: CommunityFeedScreen.listKey,
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: feed.posts.length + 1,
        separatorBuilder: (BuildContext _, int __) =>
            const SizedBox(height: 12),
        itemBuilder: (BuildContext context, int index) {
          if (index == feed.posts.length) {
            return _Footer(feed: feed);
          }
          return _PostCard(post: feed.posts[index], now: now);
        },
      ),
    );
  }
}

class _LoadingPlaceholder extends StatelessWidget {
  const _LoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: CommunityFeedScreen.loadingKey,
      child: SizedBox(
        height: 32,
        width: 32,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: careblazersColors.primarySoft,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: CommunityFeedScreen.emptyStateKey,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.forum_outlined,
            size: 56,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'Be the first to post.',
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "When you're stuck on something, chances are another Careblazer "
            'has been there too. Share a moment and the community shows up.',
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.text,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Soft placeholder for the Learn / Support segments until Phases 14.37
/// / 14.38 land the real screens. Centered icon + heading + one warm,
/// non-clinical line so the swap reads as intentional rather than empty.
class _SegmentPlaceholder extends StatelessWidget {
  const _SegmentPlaceholder({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(icon, size: 56, color: careblazersColors.primarySoft),
          const SizedBox(height: 16),
          Text(
            title,
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.feed});

  final CommunityFeedState feed;

  @override
  Widget build(BuildContext context) {
    if (feed.isLoadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            key: CommunityFeedScreen.loadMoreSpinnerKey,
            height: 22,
            width: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: careblazersColors.primarySoft,
            ),
          ),
        ),
      );
    }
    if (feed.error != null) {
      final TextTheme textTheme = Theme.of(context).textTheme;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          "Couldn't load more right now. Pull to refresh.",
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.accentDeep,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }
    return const SizedBox(height: 8);
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: CommunityFeedScreen.errorKey,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: careblazersColors.primarySoft,
            ),
            const SizedBox(height: 12),
            Text(
              "We couldn't load the community feed.",
              style: textTheme.bodyLarge?.copyWith(
                color: careblazersColors.text,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              message,
              style: textTheme.bodyMedium?.copyWith(
                color: careblazersColors.primarySoft,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: careblazersColors.cta,
                foregroundColor: Colors.white,
              ),
              onPressed: onRetry,
              child: Text(
                'Try again',
                style: textTheme.labelLarge?.copyWith(
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({required this.post, required this.now});

  final ForumPost post;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String displayName = displayNameForAuthor(post.authorId);
    final String time = relativeTime(post.createdAt, now);

    return Semantics(
      button: true,
      label: '${post.title}. Posted by $displayName, $time. '
          '${post.voteCount} votes, ${post.commentCount} comments. '
          'Double-tap to open.',
      child: Material(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: CommunityFeedScreen.postTileKey(post.id),
          borderRadius: BorderRadius.circular(16),
          // Hand the already-fetched [ForumPost] along as `extra` so
          // the detail header renders immediately instead of blanking
          // while the per-post fetch lands (Phase 13.11).
          onTap: () => context.goNamed(
            CareblazersRoutes.communityPostDetail,
            pathParameters: <String, String>{'postId': post.id},
            extra: post,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _AuthorRow(
                  displayName: displayName,
                  time: time,
                ),
                const SizedBox(height: 10),
                Text(
                  post.title,
                  style: textTheme.titleLarge?.copyWith(
                    color: careblazersColors.primary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (post.body.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    post.body,
                    style: textTheme.bodyMedium?.copyWith(
                      color: careblazersColors.text,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 12),
                _CountsRow(
                  voteCount: post.voteCount,
                  commentCount: post.commentCount,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthorRow extends StatelessWidget {
  const _AuthorRow({required this.displayName, required this.time});

  final String displayName;
  final String time;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        _Avatar(displayName: displayName),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                displayName,
                style: textTheme.bodyMedium?.copyWith(
                  color: careblazersColors.primary,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                time,
                style: textTheme.bodyMedium?.copyWith(
                  color: careblazersColors.primarySoft,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.displayName});

  final String displayName;

  @override
  Widget build(BuildContext context) {
    final String initial = displayName.isEmpty
        ? '?'
        : displayName.substring(0, 1).toUpperCase();
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: careblazersColors.primary,
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: careblazersColors.background,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _CountsRow extends StatelessWidget {
  const _CountsRow({required this.voteCount, required this.commentCount});

  final int voteCount;
  final int commentCount;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Icon(
          Icons.arrow_upward,
          size: 18,
          color: careblazersColors.primarySoft,
        ),
        const SizedBox(width: 4),
        Text(
          '$voteCount',
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.primarySoft,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 20),
        Icon(
          Icons.mode_comment_outlined,
          size: 18,
          color: careblazersColors.primarySoft,
        ),
        const SizedBox(width: 4),
        Text(
          '$commentCount',
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.primarySoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Derive a stable, non-PII display name from the author's profile id.
///
/// Phase 13.10 lands before the feed wire carries a denormalized
/// `display_name` per post; until then the screen renders a
/// `Caregiver_<first 6 chars of profile id>` placeholder so each author
/// still reads as a distinct human in the list. Matches the
/// `Caregiver_xxxxxx` shape the bootstrap endpoint mints for fresh
/// profiles (BUILD_SPEC.md §13 / Phase 13.4) so a future swap to the
/// wire value won't visually shift authors that already match.
///
/// Exported (not `@visibleForTesting`) so the post-detail screen
/// (Phase 13.11) can reuse the same derivation — both surfaces must
/// agree on what each author is called.
String displayNameForAuthor(String authorId) {
  if (authorId.isEmpty) return 'Caregiver';
  // Strip a "profile-" prefix if one shows up so the rendered suffix
  // is actually distinguishing entropy rather than a shared header.
  String rest = authorId;
  for (final String prefix in <String>['profile-', 'user-', 'careblazer-']) {
    if (rest.startsWith(prefix)) {
      rest = rest.substring(prefix.length);
      break;
    }
  }
  final String suffix =
      rest.length >= 6 ? rest.substring(0, 6) : rest;
  return 'Caregiver_$suffix';
}

/// "5m ago / 2h ago / 3d ago" relative-time formatter, anchored on [now].
///
/// Caps at "30d ago" — after a month, falls back to a short
/// "MMM d" date string so the post age stays legible without a year
/// suffix (the feed only surfaces recent activity in practice; older
/// archives are a Phase 13.11+ concern). Future timestamps (clock
/// skew between phone + Worker) render as "just now" rather than a
/// negative duration so the screen never emits broken copy.
///
/// Shared with the post-detail screen (Phase 13.11) so a post tile
/// and its detail header both read "5m ago" at the same moment.
String relativeTime(DateTime when, DateTime now) {
  final Duration delta = now.difference(when);
  if (delta.inSeconds < 60) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  if (delta.inDays < 30) return '${delta.inDays}d ago';
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[when.month - 1]} ${when.day}';
}

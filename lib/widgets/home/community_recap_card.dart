import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/forum.dart';
import '../../providers/community_feed_provider.dart';
import '../../routing/router.dart' show HoldcloseRoutes;
import '../../screens/community/community_feed_screen.dart'
    show relativeTime;
import '../../providers/home_clock_provider.dart';
import '../../services/forum_api_client.dart' show forumBackendConfigured;
import '../../theme.dart';

/// The "From the Community" recap card — a compact glance at a few recent
/// community posts at the very bottom of the Home "Today" scroll (alpha
/// feedback fb_1780962188695173).
///
/// Reads the SAME [communityFeedProvider] the Community feed screen reads
/// — no new fetch path — and surfaces the top few posts (title + a hint
/// of activity: votes · comments · relative time). Tapping any row, or
/// the header's "Community →" affordance, switches to the Community tab.
///
/// Fail-safe by construction. The community backend is optional: when it
/// isn't configured the feed falls back to the in-memory fake (which may
/// be empty), and a real backend can be slow or down. So:
///   - **loading** — the card paints nothing (no skeleton clutter at the
///     bottom of an already-busy dashboard);
///   - **empty** — the card collapses entirely (no hollow shell, no
///     "nothing here yet" nag);
///   - **error** — same as empty; Home never throws a red box or an error
///     line at a caregiver. The recap is a nicety, not a load-bearing card.
class CommunityRecapCard extends ConsumerStatefulWidget {
  const CommunityRecapCard({super.key});

  /// Test/golden handle for the whole card.
  static const Key cardKey = Key('home-community-recap-card');

  /// The header's tap-through to the Community tab.
  static const Key viewCommunityKey = Key('home-community-recap-view');

  /// Per-post row handle.
  static Key rowKey(String postId) => Key('home-community-recap-row-$postId');

  /// How many recent posts the recap surfaces. Three keeps the card a
  /// glance, not a second feed.
  static const int _maxPosts = 3;

  static const double _radius = 16;

  @override
  ConsumerState<CommunityRecapCard> createState() =>
      _CommunityRecapCardState();
}

class _CommunityRecapCardState extends ConsumerState<CommunityRecapCard> {
  @override
  void initState() {
    super.initState();
    // The community feed provider is `keepAlive: false` and is normally only
    // driven by the Community screen, so a passive `ref.watch` from the Home
    // dashboard can sit in its initial empty state — the recap never showed
    // even with posts on file (alpha fb_1780965223686636). Force a fresh
    // fetch when the dashboard mounts; it also picks up a just-created post.
    // Post-frame so we never mutate a provider during the first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(communityFeedProvider.notifier).refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final CommunityFeedState feed = ref.watch(communityFeedProvider);
    final DateTime now = ref.watch(homeClockProvider)();

    final List<ForumPost> posts = feed.posts
        .take(CommunityRecapCard._maxPosts)
        .toList(growable: false);

    // Collapse to nothing ONLY in a build with no real community backend
    // (demo/test) AND no posts — so the dashboard stays clean there. With a
    // real backend the recap is ALWAYS shown so the section is discoverable:
    // posts when there are any, a gentle prompt when not.
    if (posts.isEmpty && !forumBackendConfigured) {
      return const SizedBox.shrink();
    }

    void openCommunity() =>
        GoRouter.of(context).goNamed(HoldcloseRoutes.community);

    return Material(
      color: context.hc.surfaceWarm,
      borderRadius: BorderRadius.circular(CommunityRecapCard._radius),
      child: Padding(
        key: CommunityRecapCard.cardKey,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _Header(onTapCommunity: openCommunity),
            const SizedBox(height: 12),
            if (posts.isEmpty)
              _EmptyRow(onTap: openCommunity)
            else
              for (final ForumPost p in posts)
                _PostRow(post: p, now: now, onTap: openCommunity),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onTapCommunity});

  final VoidCallback onTapCommunity;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Text(
            'From the Community',
            style: tt.titleLarge?.copyWith(color: context.hc.primary),
          ),
        ),
        TextButton(
          key: CommunityRecapCard.viewCommunityKey,
          onPressed: onTapCommunity,
          style: TextButton.styleFrom(
            foregroundColor: context.hc.link,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Community →'),
        ),
      ],
    );
  }
}

/// Shown when the community has no posts yet (real backend only) — keeps the
/// "From the Community" section visible + invites a first post.
class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.onTap});

  static const Key emptyKey = Key('home-community-recap-empty');

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return InkWell(
      key: emptyKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          'No posts yet — tap to start a conversation.',
          style: tt.bodyMedium?.copyWith(color: context.hc.primarySoft),
        ),
      ),
    );
  }
}

class _PostRow extends StatelessWidget {
  const _PostRow({
    required this.post,
    required this.now,
    required this.onTap,
  });

  final ForumPost post;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final String time = relativeTime(post.createdAt, now);
    return InkWell(
      key: CommunityRecapCard.rowKey(post.id),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              post.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.bodyLarge?.copyWith(
                color: context.hc.text,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            // Activity hint — votes · comments · relative time, in the
            // same muted soft-navy the feed uses for its counts row.
            Text(
              '${post.voteCount} ${_plural(post.voteCount, 'vote')}'
              '  ·  ${post.commentCount} '
              '${_plural(post.commentCount, 'reply', 'replies')}'
              '  ·  $time',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.bodyMedium?.copyWith(
                color: context.hc.primarySoft,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _plural(int count, String singular, [String? plural]) {
    if (count == 1) return singular;
    return plural ?? '${singular}s';
  }
}

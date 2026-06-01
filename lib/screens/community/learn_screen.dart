import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../routing/router.dart' show CareblazersRoutes;
import '../../seed/learn_content.dart';
import '../../theme.dart';

/// The **Learn** segment of the Community tab (BUILD_SPEC.md §5.16,
/// TASKS.md Phase 14.37) — the Careblazers content library.
///
/// Rendered as the in-tab body when the Community sub-nav's Learn segment
/// is active (it is NOT a routed screen of its own; the
/// `CommunityFeedScreen` owns the Scaffold + sub-nav). Top to bottom:
///
///   * **Videos** — a vertical list of seeded framework videos
///     ([learnVideos]). Each card carries a thumbnail placeholder (real
///     video hosting is deferred to a later phase), the title, the run
///     length, and a "Watch" button that pushes
///     `/community/learn/videos/:id`.
///   * **Playbooks** — the seeded "what do I do when…" guides
///     ([learnPlaybooks]), grouped under their [LearnTopic] header. Each
///     row pushes `/community/learn/playbooks/:id`.
///
/// Content is operator-curated + locked (see `lib/seed/learn_content.dart`).
/// Stateless — the seed lists drive every row.
class LearnScreen extends StatelessWidget {
  const LearnScreen({super.key});

  static const Key listKey = Key('learn-list');

  /// Per-video card + its Watch button, keyed by video id so tests tap by
  /// id rather than by a copy string.
  static Key videoCardKey(String id) => Key('learn-video-$id');
  static Key watchButtonKey(String id) => Key('learn-watch-$id');

  /// Per-topic section header + per-playbook row keys.
  static Key topicHeaderKey(LearnTopic topic) =>
      Key('learn-topic-${topic.name}');
  static Key playbookRowKey(String id) => Key('learn-playbook-$id');

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return ListView(
      key: listKey,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: <Widget>[
        const _SectionHeader(label: 'Videos'),
        const SizedBox(height: 4),
        Text(
          "Short primers on Dr. Natali's framework.",
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.primarySoft,
          ),
        ),
        const SizedBox(height: 12),
        for (final LearnVideo video in learnVideos) ...<Widget>[
          _VideoCard(video: video),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),
        const _SectionHeader(label: 'Playbooks'),
        const SizedBox(height: 4),
        Text(
          'Step-by-step guides for the moments that keep coming up.',
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.primarySoft,
          ),
        ),
        const SizedBox(height: 12),
        for (final LearnTopic topic in LearnTopic.values)
          ..._topicGroup(topic),
      ],
    );
  }

  /// A topic header + its playbook rows, or an empty list when the topic
  /// has no seeded playbooks (skipped so the section never shows a bare
  /// header).
  List<Widget> _topicGroup(LearnTopic topic) {
    final List<LearnPlaybook> playbooks = learnPlaybooksForTopic(topic);
    if (playbooks.isEmpty) return const <Widget>[];
    return <Widget>[
      _TopicHeader(topic: topic),
      const SizedBox(height: 8),
      for (final LearnPlaybook playbook in playbooks) ...<Widget>[
        _PlaybookRow(playbook: playbook),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 8),
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      label,
      style: textTheme.titleLarge?.copyWith(
        color: careblazersColors.primary,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _TopicHeader extends StatelessWidget {
  const _TopicHeader({required this.topic});

  final LearnTopic topic;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: LearnScreen.topicHeaderKey(topic),
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Text(
        topic.label,
        style: textTheme.titleLarge?.copyWith(
          color: careblazersColors.primarySoft,
        ),
      ),
    );
  }
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.video});

  final LearnVideo video;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Material(
      key: LearnScreen.videoCardKey(video.id),
      color: careblazersColors.surfaceWarm,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Thumbnail(durationLabel: video.durationLabel),
            const SizedBox(height: 12),
            Text(
              video.title,
              style: textTheme.titleLarge?.copyWith(
                color: careblazersColors.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              video.blurb,
              style: textTheme.bodyMedium?.copyWith(
                color: careblazersColors.text,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Icon(
                  Icons.schedule,
                  size: 18,
                  color: careblazersColors.primarySoft,
                ),
                const SizedBox(width: 4),
                Text(
                  video.durationLabel,
                  style: textTheme.bodyMedium?.copyWith(
                    color: careblazersColors.primarySoft,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                _WatchButton(video: video),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.durationLabel});

  final String durationLabel;

  @override
  Widget build(BuildContext context) {
    // Placeholder until real video hosting lands (Phase 14.37 note). A
    // navy panel with a centered play glyph reads as "video" without a
    // real frame to show.
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: careblazersColors.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Icon(
            Icons.play_circle_outline,
            size: 48,
            color: careblazersColors.background,
          ),
        ),
      ),
    );
  }
}

class _WatchButton extends StatelessWidget {
  const _WatchButton({required this.video});

  final LearnVideo video;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Watch ${video.title}, ${video.durationLabel}.',
      child: ElevatedButton.icon(
        key: LearnScreen.watchButtonKey(video.id),
        onPressed: () => context.pushNamed(
          CareblazersRoutes.communityLearnVideo,
          pathParameters: <String, String>{'id': video.id},
        ),
        icon: const Icon(Icons.play_arrow, color: Colors.white, size: 20),
        label: Text(
          'Watch',
          style: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: careblazersColors.cta,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        ),
      ),
    );
  }
}

class _PlaybookRow extends StatelessWidget {
  const _PlaybookRow({required this.playbook});

  final LearnPlaybook playbook;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '${playbook.title}. ${playbook.steps.length} steps. '
          'Double-tap to open.',
      child: Material(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: LearnScreen.playbookRowKey(playbook.id),
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.pushNamed(
            CareblazersRoutes.communityLearnPlaybook,
            pathParameters: <String, String>{'id': playbook.id},
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        playbook.title,
                        style: textTheme.bodyLarge?.copyWith(
                          color: careblazersColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        playbook.summary,
                        style: textTheme.bodyMedium?.copyWith(
                          color: careblazersColors.text,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: careblazersColors.primarySoft,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

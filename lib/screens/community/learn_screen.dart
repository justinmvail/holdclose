import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/link_launcher_provider.dart';
import '../../routing/router.dart' show HoldcloseRoutes;
import '../../seed/learn_content.dart';
import '../../theme.dart';

/// The **Learn** segment of the Community tab (BUILD_SPEC.md §5.16,
/// TASKS.md Phase 14.37) — the Holdclose content library.
///
/// Rendered as the in-tab body when the Community sub-nav's Learn segment
/// is active (it is NOT a routed screen of its own; the
/// `CommunityFeedScreen` owns the Scaffold + sub-nav). Top to bottom:
///
///   * **Videos** — a vertical list of seeded primer videos
///     ([learnVideos]). Each card shows the YouTube thumbnail, the title,
///     and the run length; tapping deep-links to the video via
///     [linkLauncherProvider] (no in-app detail screen — alpha feedback
///     fb_1780932492880889). The whole section hides when no videos are
///     seeded (the de-brand left the curated list empty for now).
///   * **Playbooks** — the seeded "what do I do when…" guides
///     ([learnPlaybooks]), grouped under their [LearnTopic] header. Each
///     row pushes `/community/learn/playbooks/:id`.
///
/// Content is operator-curated + locked (see `lib/seed/learn_content.dart`).
/// Stateless — the seed lists drive every row.
class LearnScreen extends StatelessWidget {
  const LearnScreen({super.key});

  static const Key listKey = Key('learn-list');

  /// Per-video card, keyed by video id so tests tap by id rather than by a
  /// copy string. The whole card is the tap target (opens YouTube).
  static Key videoCardKey(String id) => Key('learn-video-$id');

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
        if (learnVideos.isNotEmpty) ...<Widget>[
          const _SectionHeader(label: 'Videos'),
          const SizedBox(height: 4),
          Text(
            'Short primers on caregiving.',
            style: textTheme.bodyMedium?.copyWith(
              color: context.hc.primarySoft,
            ),
          ),
          const SizedBox(height: 12),
          for (final LearnVideo video in learnVideos) ...<Widget>[
            _VideoCard(video: video),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 12),
        ],
        const _SectionHeader(label: 'Playbooks'),
        const SizedBox(height: 4),
        Text(
          'Step-by-step guides for the moments that keep coming up.',
          style: textTheme.bodyMedium?.copyWith(
            color: context.hc.primarySoft,
          ),
        ),
        const SizedBox(height: 12),
        for (final LearnTopic topic in LearnTopic.values) ..._topicGroup(topic),
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
        color: context.hc.primary,
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
          color: context.hc.primarySoft,
        ),
      ),
    );
  }
}

class _VideoCard extends ConsumerWidget {
  const _VideoCard({required this.video});

  final LearnVideo video;

  Future<void> _openOnYouTube(WidgetRef ref) =>
      ref.read(linkLauncherProvider).launch(Uri.parse(video.youtubeUrl));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: 'Play ${video.title} on YouTube',
        child: Material(
          color: context.hc.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: LearnScreen.videoCardKey(video.id),
            borderRadius: BorderRadius.circular(16),
            onTap: () => _openOnYouTube(ref),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _Thumbnail(video: video),
                  const SizedBox(height: 12),
                  Text(
                    video.title,
                    style: textTheme.titleLarge?.copyWith(
                      color: context.hc.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    video.blurb,
                    style: textTheme.bodyMedium?.copyWith(
                      color: context.hc.text,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (video.durationLabel != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.schedule,
                          size: 18,
                          color: context.hc.primarySoft,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          video.durationLabel!,
                          style: textTheme.bodyMedium?.copyWith(
                            color: context.hc.primarySoft,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The real YouTube thumbnail (`hqdefault.jpg` — the most reliably present
/// frame) with a play-button overlay. While the image loads, and if it
/// ever fails to load, the soft navy placeholder panel renders instead so
/// the card never shows a broken image (and so goldens stay deterministic,
/// since network images don't load under test).
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.video});

  final LearnVideo video;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Image.network(
              video.thumbnailUrl,
              fit: BoxFit.cover,
              loadingBuilder: (
                BuildContext context,
                Widget child,
                ImageChunkEvent? progress,
              ) {
                if (progress == null) return child;
                return const _ThumbnailPlaceholder();
              },
              errorBuilder: (
                BuildContext context,
                Object error,
                StackTrace? stackTrace,
              ) =>
                  const _ThumbnailPlaceholder(),
            ),
            // Play-button overlay sits above the thumbnail (or placeholder).
            Center(
              child: Icon(
                Icons.play_circle_outline,
                size: 48,
                color: context.hc.background,
                shadows: const <Shadow>[
                  Shadow(blurRadius: 8, color: Colors.black54),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The soft navy fallback panel shown while the thumbnail loads or when it
/// fails. Deterministic (no network) so goldens are stable.
class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: context.hc.primary);
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
        color: context.hc.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: LearnScreen.playbookRowKey(playbook.id),
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.pushNamed(
            HoldcloseRoutes.communityLearnPlaybook,
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
                          color: context.hc.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        playbook.summary,
                        style: textTheme.bodyMedium?.copyWith(
                          color: context.hc.text,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: context.hc.primarySoft,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

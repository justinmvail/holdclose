import 'package:flutter/material.dart';

import '../../seed/learn_content.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// Playbook detail at `/community/learn/playbooks/:id` (BUILD_SPEC.md
/// §5.16, TASKS.md Phase 14.37).
///
/// Renders the seeded [LearnPlaybook] as **ordered step cards** — a
/// numbered, navy-badged card per [PlaybookStep] — under a [PathHeader]
/// (`Home › Community › Learn`, back to Learn) and a topic chip. Content is
/// locked + operator-curated (`lib/seed/learn_content.dart`); this screen
/// is a pure read view.
class LearnPlaybookDetailScreen extends StatelessWidget {
  const LearnPlaybookDetailScreen({super.key, required this.playbookId});

  /// Playbook id pulled from `/community/learn/playbooks/:id`.
  final String playbookId;

  static const Key scrollKey = Key('learn-playbook-detail-scroll');
  static const Key missingKey = Key('learn-playbook-detail-missing');

  /// Per-step card key so tests target a stable node rather than copy.
  static Key stepCardKey(int index) => Key('learn-playbook-step-$index');

  @override
  Widget build(BuildContext context) {
    final LearnPlaybook? playbook = learnPlaybookById(playbookId);
    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: playbook == null
            ? const _MissingView()
            : _DetailBody(playbook: playbook),
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.playbook});

  final LearnPlaybook playbook;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      key: LearnPlaybookDetailScreen.scrollKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          PathHeader(
            breadcrumbs: const <PathHeaderCrumb>[
              PathHeaderCrumb(label: 'Home', route: '/'),
              PathHeaderCrumb(label: 'Community', route: '/community'),
              PathHeaderCrumb(label: 'Learn'),
            ],
            title: playbook.title,
            backLabel: 'Back to Learn',
            leadingIcon: Icons.menu_book_outlined,
          ),
          const SizedBox(height: 16),
          _TopicChip(topic: playbook.topic),
          const SizedBox(height: 12),
          Text(
            playbook.summary,
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.text,
            ),
          ),
          const SizedBox(height: 24),
          for (int i = 0; i < playbook.steps.length; i++) ...<Widget>[
            _StepCard(index: i, step: playbook.steps[i]),
            if (i < playbook.steps.length - 1) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _TopicChip extends StatelessWidget {
  const _TopicChip({required this.topic});

  final LearnTopic topic;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: careblazersColors.link.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        topic.label,
        style: textTheme.bodyMedium?.copyWith(
          color: careblazersColors.link,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.index, required this.step});

  final int index;
  final PlaybookStep step;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: LearnPlaybookDetailScreen.stepCardKey(index),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _StepBadge(number: index + 1),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  step.title,
                  style: textTheme.titleLarge?.copyWith(
                    color: careblazersColors.primary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  step.body,
                  style: textTheme.bodyLarge?.copyWith(
                    color: careblazersColors.text,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: 'Step $number',
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: careblazersColors.primary,
          shape: BoxShape.circle,
        ),
        child: Text(
          '$number',
          style: textTheme.titleLarge?.copyWith(
            color: careblazersColors.background,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _MissingView extends StatelessWidget {
  const _MissingView();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: PathHeader(
            breadcrumbs: <PathHeaderCrumb>[
              PathHeaderCrumb(label: 'Home', route: '/'),
              PathHeaderCrumb(label: 'Community', route: '/community'),
              PathHeaderCrumb(label: 'Learn'),
            ],
            title: 'Playbook',
            backLabel: 'Back to Learn',
            leadingIcon: Icons.menu_book_outlined,
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              key: LearnPlaybookDetailScreen.missingKey,
              padding: const EdgeInsets.all(24),
              child: Text(
                'This playbook is no longer available.',
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

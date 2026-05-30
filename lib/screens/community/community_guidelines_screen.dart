import 'package:flutter/material.dart';

import '../../seed/community_guidelines.dart';
import '../../theme.dart';

/// Locked, scrollable read of [communityGuidelines] (BUILD_SPEC.md §13 /
/// Phase 13.12).
///
/// Two entry points:
///   * Direct nav from the "Read community guidelines" link on the
///     compose screen — render as a full-page scaffold with a back
///     arrow.
///   * Embedded as the body of the first-post acknowledgement modal
///     so the caregiver can scroll the four sections inline. The
///     modal renders [CommunityGuidelinesScreen.embedded] (no
///     scaffold chrome) and pairs the content with an "I've read
///     them" CTA in the modal footer.
///
/// Content lives in [communityGuidelines]; this widget is a layout —
/// editing the rules means editing the seed file and shipping the spec
/// change, not editing this screen.
class CommunityGuidelinesScreen extends StatelessWidget {
  const CommunityGuidelinesScreen({super.key}) : _embedded = false;

  /// Render without the surrounding Scaffold/AppBar — used by the
  /// first-post acknowledgement modal so the modal frame supplies the
  /// chrome instead.
  const CommunityGuidelinesScreen.embedded({super.key}) : _embedded = true;

  final bool _embedded;

  static const Key scrollViewKey = Key('community-guidelines-scroll');
  static Key sectionKey(int index) => Key('community-guidelines-section-$index');

  @override
  Widget build(BuildContext context) {
    final Widget body = _GuidelinesContent();
    if (_embedded) {
      return body;
    }
    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text('Community guidelines'),
      ),
      body: SafeArea(child: body),
    );
  }
}

class _GuidelinesContent extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      key: CommunityGuidelinesScreen.scrollViewKey,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'The four agreements.',
            style: textTheme.headlineMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'A two-minute read. These are the lines we hold each other to.',
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.text.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 20),
          for (int i = 0; i < communityGuidelines.length; i++) ...<Widget>[
            _GuidelineSectionCard(
              key: CommunityGuidelinesScreen.sectionKey(i),
              section: communityGuidelines[i],
            ),
            if (i < communityGuidelines.length - 1)
              const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _GuidelineSectionCard extends StatelessWidget {
  const _GuidelineSectionCard({super.key, required this.section});

  final CommunityGuidelineSection section;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            section.title,
            style: textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            section.body,
            style: textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

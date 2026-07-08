import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../seed/community_guidelines.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

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
    if (_embedded) {
      // Chrome-less body for the first-post acknowledgement modal — no
      // PathHeader, the modal frame supplies its own chrome.
      return const _GuidelinesContent();
    }
    // Full-page route: the PathHeader is the header (no AppBar). The
    // canonical breadcrumb parent is the Community tab even though the
    // immediate pusher is the compose screen.
    return Scaffold(
      backgroundColor: context.hc.background,
      body: const SafeArea(child: _GuidelinesContent(showHeader: true)),
    );
  }
}

class _GuidelinesContent extends StatelessWidget {
  const _GuidelinesContent({this.showHeader = false});

  /// Whether to render the [PathHeader] at the top of the scroll. True on
  /// the full-page route; false in the embedded modal body (the modal
  /// supplies its own chrome).
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    // Localization / i18n (#18). Screen-local chrome strings (header,
    // breadcrumbs, headline, subtitle) come from the ARB-backed
    // AppLocalizations. The four guideline section bodies stay sourced
    // from `communityGuidelines` — that copy is deliberately treated as
    // locked content/spec, not config (see seed/community_guidelines.dart),
    // and is out of scope for this framework-establishing conversion.
    final AppLocalizations l10n = AppLocalizations.of(context);
    return SingleChildScrollView(
      key: CommunityGuidelinesScreen.scrollViewKey,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (showHeader) ...<Widget>[
            PathHeader(
              breadcrumbs: <PathHeaderCrumb>[
                PathHeaderCrumb(label: l10n.navHome, route: '/'),
                PathHeaderCrumb(label: l10n.navCommunity, route: '/community'),
                PathHeaderCrumb(label: l10n.communityGuidelinesTitle),
              ],
              title: l10n.communityGuidelinesTitle,
              backLabel: l10n.communityGuidelinesBack,
              leadingIcon: Icons.menu_book_outlined,
            ),
            const SizedBox(height: 20),
          ],
          Text(
            l10n.communityGuidelinesHeadline,
            style: textTheme.headlineMedium,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.communityGuidelinesSubtitle,
            style: textTheme.bodyMedium?.copyWith(
              color: context.hc.text.withValues(alpha: 0.7),
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
        color: context.hc.surfaceWarm,
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

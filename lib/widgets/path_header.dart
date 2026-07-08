import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/feedback_service.dart'
    show feedbackUiEnabled, feedbackTriggerProvider;
import '../theme.dart';

/// One segment of a [PathHeader] breadcrumb trail (BUILD_SPEC.md §4.1
/// path-header invariant, docs/MENU_LAYOUT_SPEC.md "Path header").
///
/// A non-null [route] makes the crumb a tap target that navigates up to
/// that location via `context.go`. The **terminal** crumb (the current
/// page) carries a null [route] — it renders as plain navy text, never a
/// tap target.
@immutable
class PathHeaderCrumb {
  const PathHeaderCrumb({required this.label, this.route});

  /// Word label shown in the trail, e.g. `Home`, `Medical`.
  final String label;

  /// `context.go` target for this crumb, or null for the terminal
  /// (current-page) crumb.
  final String? route;

  bool get isTappable => route != null;
}

/// Reusable header at the top of every feature page (BUILD_SPEC.md §4.1,
/// docs/MENU_LAYOUT_SPEC.md). Renders, top to bottom:
///
/// 1. A **title row** — the page title (`headlineMedium`, navy) with an
///    optional 24px leading [leadingIcon] and the standard top-right
///    actions cluster (report + profile).
/// 2. A **breadcrumb row** directly beneath it — e.g.
///    `Home › Care › Medications` — with `›` separators. Every page's trail
///    starts from **Home** (prepended automatically when a screen's trail
///    doesn't already), so the format + position are identical everywhere,
///    and the tab landings read `Home › Care` / `Home › Chat` etc. Every
///    non-terminal segment is tappable and calls `context.go(crumb.route)`,
///    so the parent crumb IS the back affordance — there's no separate
///    "Back" button (that was redundant with the breadcrumb and was
///    removed).
///
/// **Only the Home root suppresses the breadcrumb** — its trail is just
/// "Home", a self-referential crumb that adds nothing.
///
/// Brand tokens (BUILD_SPEC.md §3.1): navy ([HoldcloseColors.primary])
/// for crumb + title text, [HoldcloseColors.primarySoft] for the `›`
/// separators.
class PathHeader extends StatelessWidget {
  const PathHeader({
    super.key,
    required this.breadcrumbs,
    required this.title,
    this.backLabel,
    this.leadingIcon,
    this.onBack,
    this.trailing,
  });

  /// The full trail, root → current page. The last entry is the
  /// terminal crumb (its [PathHeaderCrumb.route] is null).
  final List<PathHeaderCrumb> breadcrumbs;

  /// Page title, rendered `headlineMedium` in navy.
  final String title;

  /// Retained for source compatibility but no longer rendered: the
  /// "‹ Back to X" control was removed as redundant with the breadcrumb
  /// (whose parent crumb is the back affordance). Safe to drop from call
  /// sites in a follow-up cleanup.
  final String? backLabel;

  /// Optional 24px glyph shown left of the [title].
  final IconData? leadingIcon;

  /// Vestigial — the Back control it overrode was removed. Retained so the
  /// existing call sites still compile; remove in a follow-up cleanup.
  final VoidCallback? onBack;

  /// Optional SCREEN-SPECIFIC action pinned to the right of the title row
  /// (e.g. an Add button). Sits to the LEFT of the standard top-right
  /// cluster ([_HeaderActions] — report + profile), which every header
  /// carries so those affordances are predictable on every screen.
  final Widget? trailing;

  /// Tap targets / test handles for the standard top-right cluster.
  static const Key profileButtonKey = Key('path-header-profile');
  static const Key reportButtonKey = Key('path-header-report');
  static const Key backButtonKey = Key('path-header-back');

  /// The trail actually rendered — every page starts from Home so the
  /// format is identical everywhere. A trail that doesn't already begin at
  /// Home gets a Home crumb (→ `/`) prepended, so the tab landings read
  /// "Home › Care", "Home › Chat", etc. instead of a bare title.
  List<PathHeaderCrumb> get _trail {
    if (breadcrumbs.isNotEmpty && breadcrumbs.first.label == 'Home') {
      return breadcrumbs;
    }
    return <PathHeaderCrumb>[
      const PathHeaderCrumb(label: 'Home', route: '/'),
      ...breadcrumbs,
    ];
  }

  /// Show the breadcrumb row on every page EXCEPT the Home root itself
  /// (where the trail is just "Home" — a self-referential crumb adds
  /// nothing).
  bool get _showBreadcrumbs => _trail.length > 1;

  /// Where the top-left Back button goes — the parent crumb's route (the
  /// second-to-last in the trail). Null on the Home root (no parent), which
  /// is the only page without a Back button (fb_1781046567327682).
  String? get _backRoute {
    if (_trail.length < 2) return null;
    return _trail[_trail.length - 2].route;
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Heading first, then the breadcrumb trail directly beneath it —
        // same spot + format on every page.
        _buildTitleRow(context, textTheme),
        if (_showBreadcrumbs) ...<Widget>[
          const SizedBox(height: 6),
          _buildBreadcrumbs(context, textTheme),
        ],
      ],
    );
  }

  Widget _buildBreadcrumbs(BuildContext context, TextTheme textTheme) {
    final TextStyle crumbStyle = (textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: context.hc.primary);
    final TextStyle separatorStyle = crumbStyle.copyWith(
      color: context.hc.primarySoft,
    );

    final List<PathHeaderCrumb> trail = _trail;
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < trail.length; i++) {
      children.add(_buildCrumb(context, trail[i], crumbStyle));
      if (i < trail.length - 1) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('›', style: separatorStyle),
        ));
      }
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  Widget _buildCrumb(
    BuildContext context,
    PathHeaderCrumb crumb,
    TextStyle style,
  ) {
    if (!crumb.isTappable) {
      // Terminal crumb — current page, plain navy text.
      return Text(crumb.label, style: style);
    }
    return InkWell(
      onTap: () => context.go(crumb.route!),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(crumb.label, style: style),
      ),
    );
  }

  Widget _buildTitleRow(BuildContext context, TextTheme textTheme) {
    final TextStyle titleStyle =
        (textTheme.headlineMedium ?? const TextStyle()).copyWith(
      color: context.hc.primary,
    );
    final String? backRoute = _backRoute;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        // Back button, top-left, on every page that has a parent
        // (fb_1781046567327682). Goes to the parent crumb's route — same
        // target as tapping the parent breadcrumb. Absent only on Home.
        if (backRoute != null) ...<Widget>[
          IconButton(
            key: PathHeader.backButtonKey,
            icon: const Icon(Icons.arrow_back),
            iconSize: 22,
            padding: EdgeInsets.zero,
            // ≥44×44 hit target (a11y); shrinkWrap pins the layout box to
            // exactly these constraints so the header stays compact.
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            color: context.hc.primary,
            tooltip: 'Back',
            // Prefer a true stack pop so Back returns wherever the user came
            // FROM — essential for screens reachable from many places (e.g.
            // Settings, pushed from the header gear on any screen; popping to
            // the Home breadcrumb would strand them). Fall back to the parent
            // crumb's route only when there's nothing to pop (a tab-branch
            // root, or a deep link opened cold). The tappable breadcrumbs
            // still handle explicit parent jumps.
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go(backRoute);
              }
            },
          ),
          const SizedBox(width: 4),
        ],
        if (leadingIcon != null) ...<Widget>[
          Icon(leadingIcon, size: 24, color: context.hc.primary),
          const SizedBox(width: 8),
        ],
        Expanded(child: Text(title, style: titleStyle)),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: 8),
          trailing!,
        ],
        const SizedBox(width: 4),
        const _HeaderActions(),
      ],
    );
  }
}

/// The standard top-right cluster carried by every [PathHeader]: the
/// alpha-gated report "!" button (left) + the always-present profile /
/// settings button (right). Mirrors the always-present bottom tab bar —
/// predictable chrome in a fixed spot on every screen.
///
/// Plain [StatelessWidget] so it imposes NO ProviderScope requirement on
/// the ~30 screens that use [PathHeader] — only the alpha-only report
/// button needs riverpod, and it lives in its own [ConsumerWidget] that
/// isn't built unless [feedbackUiEnabled].
class _HeaderActions extends StatelessWidget {
  const _HeaderActions();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Report a problem — alpha only; hidden in production builds.
        if (feedbackUiEnabled) const _ReportButton(),
        // Profile & settings — always present, top-right on every screen.
        IconButton(
          key: PathHeader.profileButtonKey,
          icon: const Icon(Icons.account_circle_outlined),
          iconSize: 24,
          padding: EdgeInsets.zero,
          // ≥44×44 hit target (a11y); shrinkWrap pins the layout box to
          // exactly these constraints so the header stays compact.
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          color: context.hc.primary,
          tooltip: 'Profile & settings',
          onPressed: () => context.push('/settings'),
        ),
      ],
    );
  }
}

/// The alpha-only report "!" — a [ConsumerWidget] so it can fire the
/// trigger the screenshot host ([FeedbackOverlay]) listens for. Only built
/// when [feedbackUiEnabled], so the (always-present) ProviderScope of a
/// real alpha build is the only place it ever mounts.
class _ReportButton extends ConsumerWidget {
  const _ReportButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      key: PathHeader.reportButtonKey,
      icon: const Icon(Icons.priority_high),
      iconSize: 22,
      padding: EdgeInsets.zero,
      // ≥44×44 hit target (a11y); shrinkWrap pins the layout box to
      // exactly these constraints so the header stays compact.
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      color: context.hc.cta,
      tooltip: 'Report a problem',
      onPressed: () => ref.read(feedbackTriggerProvider.notifier).fire(),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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

/// Reusable header at the top of every feature page below a hub
/// (BUILD_SPEC.md §4.1, docs/MENU_LAYOUT_SPEC.md). Renders, top to
/// bottom:
///
/// 1. A **breadcrumb row** — e.g. `Home › Medical › Medications` — with
///    `›` separators. Every non-terminal segment is tappable and calls
///    `context.go(crumb.route)`, so the parent crumb IS the back
///    affordance — there's no separate "Back" button (that was redundant
///    with the breadcrumb and was removed).
/// 2. A **title row** — the page title (`headlineMedium`, navy) with an
///    optional 24px leading [leadingIcon].
///
/// **Hub landings render the title row only.** When [breadcrumbs] has a
/// single entry the widget is at a top-level landing (Home, Chat,
/// Community, or the Medical / Care Team hubs themselves), so the
/// breadcrumb row is suppressed.
///
/// Brand tokens (BUILD_SPEC.md §3.1): navy ([CareblazersColors.primary])
/// for crumb + title text, [CareblazersColors.primarySoft] for the `›`
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

  /// Optional widget pinned to the right of the title row — typically a
  /// profile / settings affordance on a tab landing. Sits opposite the
  /// [leadingIcon] so the title can still expand to fill the middle.
  final Widget? trailing;

  /// A single crumb means this is a top-level landing — suppress the
  /// breadcrumb row and the Back control.
  bool get _isHubLanding => breadcrumbs.length == 1;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!_isHubLanding) ...<Widget>[
          _buildBreadcrumbs(context, textTheme),
          const SizedBox(height: 8),
        ],
        _buildTitleRow(context, textTheme),
      ],
    );
  }

  Widget _buildBreadcrumbs(BuildContext context, TextTheme textTheme) {
    final TextStyle crumbStyle = (textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: context.cb.primary);
    final TextStyle separatorStyle = crumbStyle.copyWith(
      color: context.cb.primarySoft,
    );

    final List<Widget> children = <Widget>[];
    for (int i = 0; i < breadcrumbs.length; i++) {
      children.add(_buildCrumb(context, breadcrumbs[i], crumbStyle));
      if (i < breadcrumbs.length - 1) {
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
      color: context.cb.primary,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (leadingIcon != null) ...<Widget>[
          Icon(leadingIcon, size: 24, color: context.cb.primary),
          const SizedBox(width: 8),
        ],
        Expanded(child: Text(title, style: titleStyle)),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: 8),
          trailing!,
        ],
      ],
    );
  }

}

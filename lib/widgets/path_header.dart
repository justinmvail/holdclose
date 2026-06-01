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
///    `context.go(crumb.route)`.
/// 2. A **title row** — the page title (`headlineMedium`, navy) with an
///    optional 24px leading [leadingIcon].
/// 3. A word-labeled **Back control** below the title, e.g.
///    `‹ Back to Medical`. Tapping it runs [onBack], or — when [onBack]
///    is null — pops if the navigator can pop, otherwise `context.go`s
///    to the deepest routed crumb. We never rely on the swipe gesture or
///    the OS back button alone (the audience skews 65+; the explicit
///    word-labeled control is an accessibility requirement).
///
/// **Hub landings render the title row only.** When [breadcrumbs] has a
/// single entry the widget is at a top-level landing (Home, Chat,
/// Community, or the Medical / Care Team hubs themselves), so the
/// breadcrumb row AND the Back control are suppressed.
///
/// Brand tokens (BUILD_SPEC.md §3.1): navy ([CareblazersColors.primary])
/// for crumb + title text, [CareblazersColors.primarySoft] for the `›`
/// separators, and the interactive-navigation accent
/// ([CareblazersColors.link]) on the Back chevron. (The
/// docs/MENU_LAYOUT_SPEC.md "teal" accent is a placeholder color the spec
/// explicitly says NOT to adopt — it maps onto the app's existing `link`
/// token, the only cool interactive accent in the palette.)
class PathHeader extends StatelessWidget {
  const PathHeader({
    super.key,
    required this.breadcrumbs,
    required this.title,
    required this.backLabel,
    this.leadingIcon,
    this.onBack,
  });

  /// The full trail, root → current page. The last entry is the
  /// terminal crumb (its [PathHeaderCrumb.route] is null).
  final List<PathHeaderCrumb> breadcrumbs;

  /// Page title, rendered `headlineMedium` in navy.
  final String title;

  /// Word label for the Back control, e.g. `Back to Medical`. The `‹`
  /// chevron is drawn by the widget; pass just the words.
  final String backLabel;

  /// Optional 24px glyph shown left of the [title].
  final IconData? leadingIcon;

  /// Tap handler for the Back control. When null the widget pops (if the
  /// route is poppable) or `context.go`s to the deepest routed crumb.
  final VoidCallback? onBack;

  /// A single crumb means this is a top-level landing — suppress the
  /// breadcrumb row and the Back control.
  bool get _isHubLanding => breadcrumbs.length == 1;

  /// The deepest crumb that still carries a route — the fallback target
  /// for the Back control when the navigator can't pop.
  PathHeaderCrumb? get _deepestRoutedCrumb {
    for (final PathHeaderCrumb crumb in breadcrumbs.reversed) {
      if (crumb.isTappable) return crumb;
    }
    return null;
  }

  void _handleBack(BuildContext context) {
    if (onBack != null) {
      onBack!();
      return;
    }
    if (context.canPop()) {
      context.pop();
      return;
    }
    final String? route = _deepestRoutedCrumb?.route;
    if (route != null) context.go(route);
  }

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
        _buildTitleRow(textTheme),
        if (!_isHubLanding) ...<Widget>[
          const SizedBox(height: 4),
          _buildBackControl(context, textTheme),
        ],
      ],
    );
  }

  Widget _buildBreadcrumbs(BuildContext context, TextTheme textTheme) {
    final TextStyle crumbStyle = (textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: careblazersColors.primary);
    final TextStyle separatorStyle = crumbStyle.copyWith(
      color: careblazersColors.primarySoft,
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

  Widget _buildTitleRow(TextTheme textTheme) {
    final TextStyle titleStyle =
        (textTheme.headlineMedium ?? const TextStyle()).copyWith(
      color: careblazersColors.primary,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (leadingIcon != null) ...<Widget>[
          Icon(leadingIcon, size: 24, color: careblazersColors.primary),
          const SizedBox(width: 8),
        ],
        Expanded(child: Text(title, style: titleStyle)),
      ],
    );
  }

  Widget _buildBackControl(BuildContext context, TextTheme textTheme) {
    final TextStyle labelStyle = (textTheme.labelLarge ?? const TextStyle())
        .copyWith(color: careblazersColors.primary);
    return InkWell(
      onTap: () => _handleBack(context),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '‹',
              style: labelStyle.copyWith(color: careblazersColors.link),
            ),
            const SizedBox(width: 4),
            Text(backLabel, style: labelStyle),
          ],
        ),
      ),
    );
  }
}

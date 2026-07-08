import 'package:flutter/material.dart';

import '../theme.dart';

/// A single large, labeled tile in a [HubGrid] (BUILD_SPEC.md §5.13–§5.14
/// tile-hub spec, docs/MENU_LAYOUT_SPEC.md §2–§3).
///
/// Composition, top to bottom:
/// 1. A **32px icon** centered on an 11-radius colored chip
///    ([chipColor]). The chip color is pulled from
///    [HoldcloseColors] by the caller — the HTML reference's
///    coral/teal/amber/plum are placeholders the layout spec explicitly
///    says to discard, so we never adopt them.
/// 2. A **15.5pt bold label** in navy ([HoldcloseColors.primary]).
/// 3. An **11pt sub-label** in body text ([HoldcloseColors.text]).
///
/// The tile is a [surfaceWarm]-filled card with an 18-radius outer
/// corner and a 1.5px brand ([HoldcloseColors.primary]) border, with a
/// 96px minimum height so the hit area stays generous for the 65+
/// audience. Tapping it fires [onTap].
class HubTile extends StatelessWidget {
  const HubTile({
    super.key,
    required this.icon,
    required this.label,
    required this.subLabel,
    required this.chipColor,
    required this.onTap,
    this.iconColor,
  });

  /// Glyph rendered at 32px inside the chip.
  final IconData icon;

  /// Primary tile label, 15.5pt bold navy.
  final String label;

  /// Short descriptor under the label, 11pt body text.
  final String subLabel;

  /// Chip background behind the icon — a [HoldcloseColors] token chosen
  /// by the caller.
  final Color chipColor;

  /// Tap handler; fires once per tap.
  final VoidCallback onTap;

  /// Icon tint on the chip. Defaults to [HoldcloseColors.background]
  /// (warm white) for contrast on a saturated chip.
  final Color? iconColor;

  static const double _iconSize = 32;
  static const double _chipRadius = 11;
  static const double _cardRadius = 18;
  static const double _borderWidth = 1.5;
  static const double _minHeight = 96;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final TextStyle labelStyle =
        (textTheme.titleLarge ?? const TextStyle()).copyWith(
      fontSize: 15.5,
      fontWeight: FontWeight.w700,
      color: context.hc.primary,
    );
    final TextStyle subLabelStyle =
        (textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontSize: 11,
      color: context.hc.text,
    );

    return Material(
      color: context.hc.surfaceWarm,
      borderRadius: BorderRadius.circular(_cardRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_cardRadius),
        child: Container(
          constraints: const BoxConstraints(minHeight: _minHeight),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_cardRadius),
            border: Border.all(
              color: context.hc.primary,
              width: _borderWidth,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: chipColor,
                  borderRadius: BorderRadius.circular(_chipRadius),
                ),
                child: Icon(
                  icon,
                  size: _iconSize,
                  color: iconColor ?? context.hc.background,
                ),
              ),
              const SizedBox(height: 10),
              Text(label, style: labelStyle),
              const SizedBox(height: 2),
              Text(subLabel, style: subLabelStyle),
            ],
          ),
        ),
      ),
    );
  }
}

/// A responsive 2-column grid of [HubTile]s — the standard tile-hub body
/// (BUILD_SPEC.md §5.13–§5.14, docs/MENU_LAYOUT_SPEC.md §2–§3).
///
/// Always two columns (the audience needs large targets; a third column
/// would shrink them below usable size), with a 12px gap between tiles
/// and 16px page padding. The whole grid lives in a single vertical
/// scroll view so a 7-tile hub never clips. Tile width is computed from
/// the available width so the grid adapts from a 360px phone up to a
/// 768px tablet while keeping two columns.
class HubGrid extends StatelessWidget {
  const HubGrid({super.key, required this.tiles});

  /// The tiles, laid out left-to-right, top-to-bottom.
  final List<HubTile> tiles;

  static const double _gap = 12;
  static const double _pagePadding = 16;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(_pagePadding),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Two equal columns separated by a single [_gap].
          final double itemWidth = (constraints.maxWidth - _gap) / 2;
          return Wrap(
            spacing: _gap,
            runSpacing: _gap,
            children: <Widget>[
              for (final HubTile tile in tiles)
                SizedBox(width: itemWidth, child: tile),
            ],
          );
        },
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../theme.dart';

/// One segment of a [SegmentedSubnav] (BUILD_SPEC.md §4.x in-tab sub-nav,
/// docs/MENU_LAYOUT_SPEC.md "in-tab sub-nav").
///
/// Carries the visible [label] and a stable [key] the caller uses to map
/// the active index back onto whatever body that segment swaps in. The
/// key never appears in the UI — it's the caller's handle, kept distinct
/// from the label so copy can change without breaking switch logic.
@immutable
class SegmentedSubnavItem {
  const SegmentedSubnavItem({required this.label, required this.key});

  /// Word label shown on the pill, e.g. `Feed`, `Learn`, `Support`.
  final String label;

  /// Stable identifier for this segment, used by the caller to decide
  /// which body to render. Not shown to the user.
  final String key;
}

/// A segmented pill control used as in-tab sub-navigation — the
/// alternative to adding a sixth bottom tab (docs/MENU_LAYOUT_SPEC.md:
/// in-tab sub-nav exists precisely to avoid a 6th tab).
///
/// Renders [items] as a single row of equal-width pills with an 8px gap
/// between them. Each pill has 11-radius corners and a bold 13.5pt label.
/// The pill at [activeIndex] is the selected one:
///
/// - **Active** — navy fill ([HoldcloseColors.primary]), white label,
///   navy border.
/// - **Inactive** — warm-white fill ([HoldcloseColors.surfaceWarm]),
///   slate label ([HoldcloseColors.text]), and a faint brand-line
///   border (navy at ~12%, the standard hairline used elsewhere in the
///   widget layer).
///
/// Tapping a pill calls [onChanged] with that pill's index; the control
/// is stateless, so the parent owns `activeIndex` and rebuilds with the
/// new value. [activeIndex] defaults to `0` (the first segment).
class SegmentedSubnav extends StatelessWidget {
  const SegmentedSubnav({
    super.key,
    required this.items,
    this.activeIndex = 0,
    required this.onChanged,
  });

  /// The segments, laid out left-to-right at equal width.
  final List<SegmentedSubnavItem> items;

  /// Index of the selected segment. Defaults to the first segment.
  final int activeIndex;

  /// Fires with the tapped segment's index. The parent updates its own
  /// state and rebuilds this control with the new [activeIndex].
  final ValueChanged<int> onChanged;

  static const double _radius = 11;
  static const double _labelSize = 13.5;
  static const double _borderWidth = 1.5;
  static const double _verticalPadding = 10;
  static const double _gap = 8;

  /// Navy ([HoldcloseColors.primary]) at ~12% alpha — the brand
  /// hairline used for inactive-pill borders (matches the subtle
  /// primary-tint borders elsewhere in `lib/widgets/`).
  static const Color _brandLine = Color(0x1F1F2A44);

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      if (i > 0) children.add(const SizedBox(width: _gap));
      children.add(Expanded(
        child: _SegmentPill(
          label: items[i].label,
          active: i == activeIndex,
          textTheme: textTheme,
          onTap: () => onChanged(i),
        ),
      ));
    }
    return Row(children: children);
  }
}

/// A single pill within a [SegmentedSubnav]. Styling switches entirely on
/// [active] per the control's contract above.
class _SegmentPill extends StatelessWidget {
  const _SegmentPill({
    required this.label,
    required this.active,
    required this.textTheme,
    required this.onTap,
  });

  final String label;
  final bool active;
  final TextTheme textTheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fill =
        active ? context.hc.primary : context.hc.surfaceWarm;
    final Color labelColor =
        active ? context.hc.background : context.hc.text;
    final Color borderColor =
        active ? context.hc.primary : SegmentedSubnav._brandLine;
    final TextStyle labelStyle =
        (textTheme.titleLarge ?? const TextStyle()).copyWith(
      fontSize: SegmentedSubnav._labelSize,
      fontWeight: FontWeight.w700,
      color: labelColor,
    );

    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(SegmentedSubnav._radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SegmentedSubnav._radius),
        child: Container(
          padding: const EdgeInsets.symmetric(
            vertical: SegmentedSubnav._verticalPadding,
            horizontal: 12,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SegmentedSubnav._radius),
            border: Border.all(
              color: borderColor,
              width: SegmentedSubnav._borderWidth,
            ),
          ),
          child: Text(
            label,
            style: labelStyle,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

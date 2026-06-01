import 'package:alchemist/alchemist.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/segmented_subnav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Feed/Learn/Support segments the Community sub-nav ships with.
const List<SegmentedSubnavItem> _items = <SegmentedSubnavItem>[
  SegmentedSubnavItem(label: 'Feed', key: 'feed'),
  SegmentedSubnavItem(label: 'Learn', key: 'learn'),
  SegmentedSubnavItem(label: 'Support', key: 'support'),
];

/// Wraps a [SegmentedSubnav] in the minimum a golden render needs: a
/// brand-background [Material] (for the InkWell pills) at a fixed width.
/// No theme is passed — per `flutter_test_config.dart`, goldens avoid
/// dragging google_fonts through the framework; the widget applies its
/// brand colors directly.
Widget _host(int activeIndex) => Container(
      width: 360,
      color: careblazersColors.background,
      child: Material(
        color: careblazersColors.background,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentedSubnav(
            items: _items,
            activeIndex: activeIndex,
            onChanged: (_) {},
          ),
        ),
      ),
    );

void main() {
  group('SegmentedSubnav golden', () {
    goldenTest(
      'renders the active pill at each of the three indices',
      fileName: 'segmented_subnav',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(name: 'active = 0 (Feed)', child: _host(0)),
          GoldenTestScenario(name: 'active = 1 (Learn)', child: _host(1)),
          GoldenTestScenario(name: 'active = 2 (Support)', child: _host(2)),
        ],
      ),
    );
  });
}

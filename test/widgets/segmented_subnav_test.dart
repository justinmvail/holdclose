import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/segmented_subnav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Feed/Learn/Support segments the Community sub-nav ships with.
const List<SegmentedSubnavItem> _items = <SegmentedSubnavItem>[
  SegmentedSubnavItem(label: 'Feed', key: 'feed'),
  SegmentedSubnavItem(label: 'Learn', key: 'learn'),
  SegmentedSubnavItem(label: 'Support', key: 'support'),
];

Future<void> _pump(
  WidgetTester tester, {
  int? activeIndex,
  required ValueChanged<int> onChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: activeIndex == null
              ? SegmentedSubnav(items: _items, onChanged: onChanged)
              : SegmentedSubnav(
                  items: _items,
                  activeIndex: activeIndex,
                  onChanged: onChanged,
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The [Text] style for a given pill label.
TextStyle? _labelStyle(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style;

void main() {
  group('SegmentedSubnav — rendering', () {
    testWidgets('renders one pill per item', (WidgetTester tester) async {
      await _pump(tester, onChanged: (_) {});

      expect(find.text('Feed'), findsOneWidget);
      expect(find.text('Learn'), findsOneWidget);
      expect(find.text('Support'), findsOneWidget);
    });

    testWidgets('labels are bold 13.5pt', (WidgetTester tester) async {
      await _pump(tester, onChanged: (_) {});

      for (final String label in <String>['Feed', 'Learn', 'Support']) {
        final TextStyle? style = _labelStyle(tester, label);
        expect(style?.fontSize, 13.5);
        expect(style?.fontWeight, FontWeight.w700);
      }
    });

    testWidgets('pills are equal width', (WidgetTester tester) async {
      await _pump(tester, onChanged: (_) {});

      final double feed = tester.getSize(find.text('Feed')).width;
      // Each label sits inside an Expanded, so the underlying pills share
      // the row evenly; compare the three pill InkWell hit areas.
      final List<double> widths = <double>[];
      for (int i = 0; i < 3; i++) {
        widths.add(tester.getSize(find.byType(InkWell).at(i)).width);
      }
      expect(widths[0], moreOrLessEquals(widths[1], epsilon: 0.5));
      expect(widths[1], moreOrLessEquals(widths[2], epsilon: 0.5));
      expect(feed, lessThan(widths[0]));
    });
  });

  group('SegmentedSubnav — active state', () {
    testWidgets('defaults to activeIndex 0', (WidgetTester tester) async {
      await _pump(tester, onChanged: (_) {});

      final SegmentedSubnav widget =
          tester.widget<SegmentedSubnav>(find.byType(SegmentedSubnav));
      expect(widget.activeIndex, 0);

      // First pill carries the active (white) label; the others slate.
      expect(_labelStyle(tester, 'Feed')?.color, holdcloseColors.background);
      expect(_labelStyle(tester, 'Learn')?.color, holdcloseColors.text);
      expect(_labelStyle(tester, 'Support')?.color, holdcloseColors.text);
    });

    testWidgets('honors an explicit activeIndex',
        (WidgetTester tester) async {
      await _pump(tester, activeIndex: 1, onChanged: (_) {});

      expect(_labelStyle(tester, 'Feed')?.color, holdcloseColors.text);
      expect(_labelStyle(tester, 'Learn')?.color, holdcloseColors.background);
      expect(_labelStyle(tester, 'Support')?.color, holdcloseColors.text);
    });

    testWidgets('active pill fills navy; inactive fills warm white',
        (WidgetTester tester) async {
      await _pump(tester, activeIndex: 2, onChanged: (_) {});

      final Iterable<Material> materials =
          tester.widgetList<Material>(find.byType(Material));
      final Set<Color?> fills = materials.map((Material m) => m.color).toSet();
      expect(fills, contains(holdcloseColors.primary));
      expect(fills, contains(holdcloseColors.surfaceWarm));
    });
  });

  group('SegmentedSubnav — interaction', () {
    testWidgets('tapping a pill fires onChanged with its index',
        (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await _pump(tester, onChanged: taps.add);

      await tester.tap(find.text('Learn'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Support'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Feed'));
      await tester.pumpAndSettle();

      expect(taps, <int>[1, 2, 0]);
    });

    testWidgets('tapping the already-active pill still reports its index',
        (WidgetTester tester) async {
      int? last;
      await _pump(tester, activeIndex: 0, onChanged: (int i) => last = i);

      await tester.tap(find.text('Feed'));
      await tester.pumpAndSettle();
      expect(last, 0);
    });
  });
}

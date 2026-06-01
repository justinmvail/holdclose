import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/hub_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Six tiles drawn from a spread of [CareblazersColors] chip tokens —
/// enough to fill three rows of a 2-column grid.
List<HubTile> _sixTiles({VoidCallback? onTap}) => <HubTile>[
      HubTile(
        icon: Icons.medication_outlined,
        label: 'Medications',
        subLabel: 'doses & reminders',
        chipColor: careblazersColors.primary,
        onTap: onTap ?? () {},
      ),
      HubTile(
        icon: Icons.schedule_outlined,
        label: 'Medication Schedule',
        subLabel: 'daily timeline',
        chipColor: careblazersColors.cta,
        onTap: onTap ?? () {},
      ),
      HubTile(
        icon: Icons.event_outlined,
        label: 'Appointments',
        subLabel: 'calendar & visits',
        chipColor: careblazersColors.accentDeep,
        onTap: onTap ?? () {},
      ),
      HubTile(
        icon: Icons.favorite_outline,
        label: 'Health Log',
        subLabel: 'symptoms & vitals',
        chipColor: careblazersColors.link,
        onTap: onTap ?? () {},
      ),
      HubTile(
        icon: Icons.list_alt_outlined,
        label: 'Care Plan',
        subLabel: 'routine & stages',
        chipColor: careblazersColors.success,
        onTap: onTap ?? () {},
      ),
      HubTile(
        icon: Icons.badge_outlined,
        label: 'Cards & Documents',
        subLabel: 'emergency card, POA, IDs',
        chipColor: careblazersColors.primarySoft,
        onTap: onTap ?? () {},
      ),
    ];

Future<void> _pumpGrid(
  WidgetTester tester,
  double width,
  List<HubTile> tiles,
) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: HubGrid(tiles: tiles))),
  );
  await tester.pumpAndSettle();
}

/// Distinct rounded top offsets among all rendered tiles — one per grid
/// row.
Set<double> _rowOffsets(WidgetTester tester) {
  final Set<double> rows = <double>{};
  final int count = tester.widgetList(find.byType(HubTile)).length;
  for (int i = 0; i < count; i++) {
    rows.add(tester.getTopLeft(find.byType(HubTile).at(i)).dy.roundToDouble());
  }
  return rows;
}

/// Distinct rounded left offsets among all rendered tiles — one per grid
/// column.
Set<double> _columnOffsets(WidgetTester tester) {
  final Set<double> cols = <double>{};
  final int count = tester.widgetList(find.byType(HubTile)).length;
  for (int i = 0; i < count; i++) {
    cols.add(tester.getTopLeft(find.byType(HubTile).at(i)).dx.roundToDouble());
  }
  return cols;
}

void main() {
  group('HubTile — rendering', () {
    testWidgets('renders icon, label and sub-label',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HubTile(
              icon: Icons.medication_outlined,
              label: 'Medications',
              subLabel: 'doses & reminders',
              chipColor: careblazersColors.primary,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('Medications'), findsOneWidget);
      expect(find.text('doses & reminders'), findsOneWidget);
      expect(find.byIcon(Icons.medication_outlined), findsOneWidget);
    });

    testWidgets('icon renders at 32px with the default warm-white tint',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HubTile(
              icon: Icons.event_outlined,
              label: 'Appointments',
              subLabel: 'calendar & visits',
              chipColor: careblazersColors.cta,
              onTap: () {},
            ),
          ),
        ),
      );

      final Icon icon = tester.widget<Icon>(find.byIcon(Icons.event_outlined));
      expect(icon.size, 32);
      expect(icon.color, careblazersColors.background);
    });

    testWidgets('honors an explicit iconColor override',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HubTile(
              icon: Icons.event_outlined,
              label: 'Appointments',
              subLabel: 'calendar & visits',
              chipColor: careblazersColors.surfaceWarm,
              iconColor: careblazersColors.primary,
              onTap: () {},
            ),
          ),
        ),
      );

      final Icon icon = tester.widget<Icon>(find.byIcon(Icons.event_outlined));
      expect(icon.color, careblazersColors.primary);
    });

    testWidgets('label is 15.5pt bold navy; sub-label is 11pt body text',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HubTile(
              icon: Icons.medication_outlined,
              label: 'Medications',
              subLabel: 'doses & reminders',
              chipColor: careblazersColors.primary,
              onTap: () {},
            ),
          ),
        ),
      );

      final Text label = tester.widget<Text>(find.text('Medications'));
      expect(label.style?.fontSize, 15.5);
      expect(label.style?.fontWeight, FontWeight.w700);
      expect(label.style?.color, careblazersColors.primary);

      final Text sub = tester.widget<Text>(find.text('doses & reminders'));
      expect(sub.style?.fontSize, 11);
      expect(sub.style?.color, careblazersColors.text);
    });

    testWidgets('the chip paints with the supplied chipColor',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HubTile(
              icon: Icons.medication_outlined,
              label: 'Medications',
              subLabel: 'doses & reminders',
              chipColor: careblazersColors.success,
              onTap: () {},
            ),
          ),
        ),
      );

      // The chip is the Container whose decoration fill equals chipColor.
      final Iterable<Container> containers =
          tester.widgetList<Container>(find.byType(Container));
      final bool hasChip = containers.any((Container c) {
        final Decoration? d = c.decoration;
        return d is BoxDecoration && d.color == careblazersColors.success;
      });
      expect(hasChip, isTrue);
    });

    testWidgets('tap fires the callback exactly once',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HubTile(
              icon: Icons.medication_outlined,
              label: 'Medications',
              subLabel: 'doses & reminders',
              chipColor: careblazersColors.primary,
              onTap: () => taps++,
            ),
          ),
        ),
      );

      await tester.tap(find.byType(HubTile));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });

  group('HubGrid — 2-column layout', () {
    for (final double width in <double>[360, 412, 768]) {
      testWidgets('lays 6 tiles into 2 columns × 3 rows at ${width}w',
          (WidgetTester tester) async {
        await _pumpGrid(tester, width, _sixTiles());

        expect(find.byType(HubTile), findsNWidgets(6));
        // Exactly two distinct x-offsets → two columns.
        expect(_columnOffsets(tester).length, 2);
        // Six tiles in two columns → three rows.
        expect(_rowOffsets(tester).length, 3);
      });
    }

    testWidgets('tiles are equal width, leaving a 12px inter-column gap',
        (WidgetTester tester) async {
      await _pumpGrid(tester, 360, _sixTiles());

      final Size first = tester.getSize(find.byType(HubTile).at(0));
      final Size second = tester.getSize(find.byType(HubTile).at(1));
      expect(first.width, moreOrLessEquals(second.width, epsilon: 0.5));

      final double leftRight =
          tester.getTopRight(find.byType(HubTile).at(0)).dx;
      final double rightLeft =
          tester.getTopLeft(find.byType(HubTile).at(1)).dx;
      expect(rightLeft - leftRight, moreOrLessEquals(12, epsilon: 0.5));
    });

    testWidgets('the grid scrolls (single scroll view)',
        (WidgetTester tester) async {
      await _pumpGrid(tester, 360, _sixTiles());
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('a tile tap inside the grid fires its callback',
        (WidgetTester tester) async {
      int taps = 0;
      await _pumpGrid(tester, 412, _sixTiles(onTap: () => taps++));

      await tester.tap(find.byType(HubTile).first);
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });
}

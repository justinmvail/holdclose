import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/form/form_error_view.dart';
import 'package:careblazers/widgets/form/format.dart';
import 'package:careblazers/widgets/form/id_factory.dart';
import 'package:careblazers/widgets/form/labelled_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FormErrorView', () {
    testWidgets('renders the message centered in branded body text',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: careblazersLightTheme,
        home: const Scaffold(
          body: FormErrorView(message: "We couldn't load the things.\nboom"),
        ),
      ));

      final Finder textFinder = find.text("We couldn't load the things.\nboom");
      expect(textFinder, findsOneWidget);
      final Text text = tester.widget<Text>(textFinder);
      expect(text.textAlign, TextAlign.center);
      expect(text.style?.color, careblazersColors.text);
      expect(
        find.ancestor(of: textFinder, matching: find.byType(Center)),
        findsWidgets,
      );
    });
  });

  group('LabelledField', () {
    testWidgets('renders a bold label above the child',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: careblazersLightTheme,
        home: const Scaffold(
          body: LabelledField(
            label: 'Name',
            child: Text('CHILD'),
          ),
        ),
      ));

      expect(find.text('Name'), findsOneWidget);
      expect(find.text('CHILD'), findsOneWidget);
      final Text label = tester.widget<Text>(find.text('Name'));
      expect(label.style?.fontWeight, FontWeight.w700);
      // Label sits above the child.
      final double labelY = tester.getTopLeft(find.text('Name')).dy;
      final double childY = tester.getTopLeft(find.text('CHILD')).dy;
      expect(labelY, lessThan(childY));
    });
  });

  group('format helpers', () {
    test('monthAbbreviations covers all twelve months in order', () {
      expect(monthAbbreviations, hasLength(12));
      expect(monthAbbreviations.first, 'Jan');
      expect(monthAbbreviations.last, 'Dec');
    });

    test('formatMonthDayYear renders "Mon d, yyyy"', () {
      expect(formatMonthDayYear(DateTime(2026, 6, 3)), 'Jun 3, 2026');
      expect(formatMonthDayYear(DateTime(2025, 12, 31)), 'Dec 31, 2025');
    });

    test('formatClock12h renders 12-hour clock with two-digit minutes', () {
      expect(formatClock12h(DateTime(2026, 6, 3, 14, 30)), '2:30 PM');
      expect(formatClock12h(DateTime(2026, 6, 3, 0, 5)), '12:05 AM');
      expect(formatClock12h(DateTime(2026, 6, 3, 12, 0)), '12:00 PM');
      expect(formatClock12h(DateTime(2026, 6, 3, 9, 7)), '9:07 AM');
    });
  });

  group('mintId', () {
    test('mints "<prefix>-<ms>-<rand>"', () {
      final DateTime moment = DateTime(2026, 6, 3, 8);
      final String id = mintId('task', clock: () => moment);
      final RegExp shape =
          RegExp('^task-${moment.millisecondsSinceEpoch}-\\d+\$');
      expect(shape.hasMatch(id), isTrue, reason: id);
    });

    test('empty prefix mints the bare "<ms>-<rand>" shape', () {
      final DateTime moment = DateTime(2026, 6, 3, 8);
      final String id = mintId('', clock: () => moment);
      final RegExp shape = RegExp('^${moment.millisecondsSinceEpoch}-\\d+\$');
      expect(shape.hasMatch(id), isTrue, reason: id);
    });

    test('defaults to the wall clock when no clock is supplied', () {
      final int before = DateTime.now().millisecondsSinceEpoch;
      final String id = mintId('x');
      final int after = DateTime.now().millisecondsSinceEpoch;
      final int ms = int.parse(id.split('-')[1]);
      expect(ms, inInclusiveRange(before, after));
    });
  });
}

import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:careblazers/screens/library/library_card_screen.dart';
import 'package:careblazers/screens/settings/settings_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Pump the real router so `context.push(...)` lands on real route
/// builders — same approach as `router_test.dart`. We skip the brand
/// theme intentionally; its google_fonts TextStyles fire fire-and-
/// forget Futures that flake in unit tests.
Future<GoRouter> _pumpHome(WidgetTester tester) async {
  final GoRouter router = buildRouter();
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('HomeScreen — BUILD_SPEC.md §5.1', () {
    testWidgets('renders the two-line primary tap target',
        (WidgetTester tester) async {
      await _pumpHome(tester);

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text("What's happening"), findsOneWidget);
      expect(find.text('right now?'), findsOneWidget);
      expect(find.text('[tap to start]'), findsOneWidget);
      expect(find.byKey(HomeScreen.primaryTargetKey), findsOneWidget);
    });

    testWidgets('AppBar title is "Careblazers"', (WidgetTester tester) async {
      await _pumpHome(tester);

      expect(find.widgetWithText(AppBar, 'Careblazers'), findsOneWidget);
    });

    testWidgets('background is surfaceWarm', (WidgetTester tester) async {
      await _pumpHome(tester);

      final Scaffold scaffold = tester.widget<Scaffold>(
        find.descendant(
          of: find.byType(HomeScreen),
          matching: find.byType(Scaffold),
        ),
      );
      expect(scaffold.backgroundColor, careblazersColors.surfaceWarm);
    });

    testWidgets('renders both secondary rows', (WidgetTester tester) async {
      await _pumpHome(tester);

      expect(find.text('Quick reassurance'), findsOneWidget);
      expect(find.text('Doctor visit prep'), findsOneWidget);
      expect(find.byKey(HomeScreen.quickReassuranceKey), findsOneWidget);
      expect(find.byKey(HomeScreen.doctorVisitPrepKey), findsOneWidget);
    });

    testWidgets('no BackButton (Home is a tab root)',
        (WidgetTester tester) async {
      await _pumpHome(tester);

      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('no emoji on the primary tap target',
        (WidgetTester tester) async {
      await _pumpHome(tester);

      // Brand voice forbids emoji on primary CTAs. The primary target
      // contains only the literal §5.1 copy.
      final Finder target = find.byKey(HomeScreen.primaryTargetKey);
      final Iterable<Text> texts =
          tester.widgetList<Text>(find.descendant(of: target, matching: find.byType(Text)));
      for (final Text text in texts) {
        final String? data = text.data;
        if (data == null) continue;
        // Quick heuristic: any character outside ASCII printable is
        // suspect on a primary CTA.
        final RegExp ascii = RegExp(r'^[\x20-\x7E]+$');
        expect(
          ascii.hasMatch(data),
          isTrue,
          reason: 'Primary CTA copy must be ASCII (no emoji): "$data"',
        );
      }
    });
  });

  group('HomeScreen — navigation', () {
    testWidgets('gear icon pushes /settings', (WidgetTester tester) async {
      await _pumpHome(tester);

      expect(find.byType(SettingsScreen), findsNothing);

      await tester.tap(find.byKey(HomeScreen.settingsGearKey));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('primary tap target pushes /decoder/behavior',
        (WidgetTester tester) async {
      await _pumpHome(tester);

      expect(find.byType(BehaviorPickerScreen), findsNothing);

      await tester.tap(find.byKey(HomeScreen.primaryTargetKey));
      await tester.pumpAndSettle();

      expect(find.byType(BehaviorPickerScreen), findsOneWidget);
      // The pushed route covers the tab shell and auto-renders a back
      // arrow.
      expect(find.byType(BackButton), findsOneWidget);
    });

    testWidgets('"Doctor visit prep" routes to /journal',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpHome(tester);

      await tester.tap(find.byKey(HomeScreen.doctorVisitPrepKey));
      await tester.pumpAndSettle();

      expect(find.byType(JournalScreen), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/journal',
      );
    });

    testWidgets('"Quick reassurance" pushes the calming library card',
        (WidgetTester tester) async {
      await _pumpHome(tester);

      await tester.tap(find.byKey(HomeScreen.quickReassuranceKey));
      await tester.pumpAndSettle();

      expect(find.byType(LibraryCardScreen), findsOneWidget);
      final LibraryCardScreen pushed = tester.widget<LibraryCardScreen>(
        find.byType(LibraryCardScreen),
      );
      expect(pushed.cardId, 'respond_to_emotion');
    });
  });
}

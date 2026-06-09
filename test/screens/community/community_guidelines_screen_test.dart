import 'package:careblazers/l10n/app_localizations.dart';
import 'package:careblazers/screens/community/community_guidelines_screen.dart';
import 'package:careblazers/seed/community_guidelines.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    // The screen reads its chrome strings via AppLocalizations.of(context)
    // (#18 localization), so the pumped MaterialApp must register the
    // generated delegate + supportedLocales — otherwise `.of(context)`
    // throws (nullable-getter: false). Mirrors how lib/app.dart wires
    // them on the real MaterialApp.router.
    const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CommunityGuidelinesScreen(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('CommunityGuidelinesScreen — BUILD_SPEC.md §13 / Phase 13.12', () {
    testWidgets(
        'renders the PathHeader title + every guideline section in order',
        (WidgetTester tester) async {
      await _pump(tester);

      // The page title now lives in the PathHeader (no AppBar). 'Community
      // guidelines' appears twice — once as the terminal breadcrumb crumb,
      // once as the title — so assert the title via the PathHeader widget
      // and scope the text expectation accordingly.
      final PathHeader header =
          tester.widget<PathHeader>(find.byType(PathHeader));
      expect(header.title, 'Community guidelines');
      // The standalone "Back to Community" control was removed; the parent
      // 'Community' breadcrumb crumb is now the back affordance. It renders
      // as a tappable InkWell-wrapped Text.
      expect(find.widgetWithText(InkWell, 'Community'), findsOneWidget);
      expect(find.text('Community guidelines'), findsWidgets);
      for (int i = 0; i < communityGuidelines.length; i++) {
        expect(
          find.byKey(CommunityGuidelinesScreen.sectionKey(i)),
          findsOneWidget,
          reason: 'expected section card $i to render',
        );
        expect(
          find.text(communityGuidelines[i].title),
          findsOneWidget,
          reason: 'expected section $i title to render',
        );
      }
    });

    testWidgets('embedded mode hides the Scaffold chrome',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        // Embedded mode reads AppLocalizations too, so the delegate +
        // supportedLocales are required here as well (#18 localization).
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: CommunityGuidelinesScreen.embedded()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Community guidelines'), findsNothing);
      expect(
        find.byKey(CommunityGuidelinesScreen.sectionKey(0)),
        findsOneWidget,
      );
    });
  });
}

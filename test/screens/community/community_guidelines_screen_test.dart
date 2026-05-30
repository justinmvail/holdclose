import 'package:careblazers/screens/community/community_guidelines_screen.dart';
import 'package:careblazers/seed/community_guidelines.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    const MaterialApp(home: CommunityGuidelinesScreen()),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('CommunityGuidelinesScreen — BUILD_SPEC.md §13 / Phase 13.12', () {
    testWidgets(
        'renders the AppBar title + every guideline section in order',
        (WidgetTester tester) async {
      await _pump(tester);

      expect(find.text('Community guidelines'), findsOneWidget);
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
        const MaterialApp(
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

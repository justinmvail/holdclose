import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/home/catch_me_up_card.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Widget coverage for the Home "catch me up" recap card, focused on the
/// trusted AI-disclosure caption (the only AI surface that had been missing
/// one). The card is the sole surface that auto-generates prose, so the
/// caption tells the caregiver it was machine-written and to spot-check it.

/// Resolves [catchMeUpProvider] synchronously to a fixed value so the test
/// never streams or touches shared_preferences.
class _StubCatchMeUp extends CatchMeUp {
  _StubCatchMeUp(this._summary);
  final String _summary;
  @override
  Future<String> build() async => _summary;
}

Future<void> _pump(WidgetTester tester, String summary) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        catchMeUpProvider.overrideWith(() => _StubCatchMeUp(summary)),
      ],
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: holdcloseColors.background,
          body: const Padding(
            padding: EdgeInsets.all(16),
            child: CatchMeUpCard(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the recap + a trusted AI-disclosure caption',
      (WidgetTester tester) async {
    await _pump(tester, 'A calm, steady day. Meds stayed on track.');

    expect(find.byKey(CatchMeUpCard.summaryKey), findsOneWidget);
    // The caption discloses the recap is machine-written and nudges a check.
    expect(find.byKey(CatchMeUpCard.captionKey), findsOneWidget);
    expect(
      find.text('Summarized by your coach from your recent log — check '
          'anything important.'),
      findsOneWidget,
    );
    // Vendor stays invisible per the brand guardrail.
    final String caption =
        (tester.widget<Text>(find.byKey(CatchMeUpCard.captionKey))).data ?? '';
    for (final String vendor in <String>[
      'ChatGPT',
      'Claude',
      'GPT',
      'OpenAI',
      'Anthropic',
      'AI',
    ]) {
      expect(caption.contains(vendor), isFalse,
          reason: 'caption must not name the vendor/model: $vendor');
    }
  });

  testWidgets('empty recap collapses the whole card (no caption)',
      (WidgetTester tester) async {
    await _pump(tester, '');
    expect(find.byKey(CatchMeUpCard.captionKey), findsNothing);
    expect(find.byKey(CatchMeUpCard.summaryKey), findsNothing);
  });
}

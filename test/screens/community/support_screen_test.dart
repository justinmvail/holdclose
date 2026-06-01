import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/screens/community/support_screen.dart';
import 'package:careblazers/seed/support_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pump the bare [SupportScreen] (the in-tab segment body) on a tall
/// surface so the expanded cards build every row without scrolling.
/// Returns the recording launcher so respite-tap tests can assert URLs.
Future<RecordingLinkLauncher> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(500, 6000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final RecordingLinkLauncher launcher = RecordingLinkLauncher();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        linkLauncherProvider.overrideWithValue(launcher),
      ],
      child: const MaterialApp(home: Scaffold(body: SupportScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return launcher;
}

/// Tap a card's header to expand it.
Future<void> _expand(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(SupportScreen.cardHeaderKey(id)));
  await tester.pumpAndSettle();
}

/// Answer every self-check question with [value].
Future<void> _answerAll(WidgetTester tester, int value) async {
  for (int i = 0; i < burnoutQuestions.length; i++) {
    await tester.tap(find.byKey(SupportScreen.likertOptionKey(i, value)));
    await tester.pump();
  }
}

void main() {
  group('SupportScreen — cards (Phase 14.38)', () {
    testWidgets('renders all three card headers collapsed', (tester) async {
      await _pump(tester);

      expect(find.text('Burnout self-check'), findsOneWidget);
      expect(find.text('Respite resources'), findsOneWidget);
      expect(find.text('Expert Q&A'), findsOneWidget);

      // Bodies are absent while collapsed.
      expect(
        find.byKey(SupportScreen.cardBodyKey(SupportScreen.selfCheckId)),
        findsNothing,
      );
      expect(
        find.byKey(SupportScreen.cardBodyKey(SupportScreen.respiteId)),
        findsNothing,
      );
      expect(
        find.byKey(SupportScreen.cardBodyKey(SupportScreen.qandaId)),
        findsNothing,
      );
    });

    testWidgets('tapping a header expands that card inline', (tester) async {
      await _pump(tester);
      await _expand(tester, SupportScreen.qandaId);

      expect(
        find.byKey(SupportScreen.cardBodyKey(SupportScreen.qandaId)),
        findsOneWidget,
      );
      // Other cards stay collapsed — expansion is independent.
      expect(
        find.byKey(SupportScreen.cardBodyKey(SupportScreen.respiteId)),
        findsNothing,
      );
    });
  });

  group('SupportScreen — burnout self-check', () {
    testWidgets('submit is disabled until every statement is answered',
        (tester) async {
      await _pump(tester);
      await _expand(tester, SupportScreen.selfCheckId);

      ElevatedButton submit() =>
          tester.widget<ElevatedButton>(find.byKey(SupportScreen.submitKey));
      expect(submit().onPressed, isNull);

      // Answer all but the last — still disabled.
      for (int i = 0; i < burnoutQuestions.length - 1; i++) {
        await tester.tap(find.byKey(SupportScreen.likertOptionKey(i, 3)));
        await tester.pump();
      }
      expect(submit().onPressed, isNull);

      // The final answer enables it.
      await tester.tap(
        find.byKey(SupportScreen.likertOptionKey(
            burnoutQuestions.length - 1, 3)),
      );
      await tester.pump();
      expect(submit().onPressed, isNotNull);
    });

    testWidgets('submitting shows the scored result inline', (tester) async {
      await _pump(tester);
      await _expand(tester, SupportScreen.selfCheckId);

      // All 5s → severe band.
      await _answerAll(tester, 5);
      await tester.tap(find.byKey(SupportScreen.submitKey));
      await tester.pumpAndSettle();

      expect(find.byKey(SupportScreen.resultKey), findsOneWidget);
      expect(find.text('Running on empty'), findsOneWidget);
      // The form is gone once the result is showing.
      expect(find.byKey(SupportScreen.submitKey), findsNothing);
    });

    testWidgets('retake returns to the empty form', (tester) async {
      await _pump(tester);
      await _expand(tester, SupportScreen.selfCheckId);

      await _answerAll(tester, 1);
      await tester.tap(find.byKey(SupportScreen.submitKey));
      await tester.pumpAndSettle();
      expect(find.text('Holding steady'), findsOneWidget);

      await tester.tap(find.byKey(SupportScreen.retakeKey));
      await tester.pumpAndSettle();

      expect(find.byKey(SupportScreen.resultKey), findsNothing);
      // Back to the form, and the previous answers are cleared, so submit
      // is disabled again.
      final ElevatedButton submit =
          tester.widget<ElevatedButton>(find.byKey(SupportScreen.submitKey));
      expect(submit.onPressed, isNull);
    });
  });

  group('SupportScreen — respite resources', () {
    testWidgets('renders every seeded resource', (tester) async {
      await _pump(tester);
      await _expand(tester, SupportScreen.respiteId);

      for (final RespiteResource resource in respiteResources) {
        expect(
          find.byKey(SupportScreen.respiteResourceKey(resource.id)),
          findsOneWidget,
          reason: '${resource.id} row should render',
        );
      }
    });

    testWidgets('tapping a phone resource launches its tel: link',
        (tester) async {
      final RecordingLinkLauncher launcher = await _pump(tester);
      await _expand(tester, SupportScreen.respiteId);

      await tester.tap(
        find.byKey(SupportScreen.respiteResourceKey('alz-helpline')),
      );
      await tester.pumpAndSettle();

      expect(launcher.launched, contains(Uri.parse('tel:18002723900')));
    });

    testWidgets('the search link launches a web search', (tester) async {
      final RecordingLinkLauncher launcher = await _pump(tester);
      await _expand(tester, SupportScreen.respiteId);

      await tester.tap(find.byKey(SupportScreen.respiteSearchKey));
      await tester.pumpAndSettle();

      expect(launcher.launched, contains(respiteSearchUrl()));
    });
  });

  group('SupportScreen — expert Q&A', () {
    testWidgets('renders every curated answer read-only', (tester) async {
      await _pump(tester);
      await _expand(tester, SupportScreen.qandaId);

      for (final ExpertAnswer entry in expertAnswers) {
        expect(
          find.byKey(SupportScreen.expertAnswerKey(entry.id)),
          findsOneWidget,
          reason: '${entry.id} entry should render',
        );
      }
    });
  });
}

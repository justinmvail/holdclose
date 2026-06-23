import 'dart:async';

import 'package:holdclose/widgets/caption_fade.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({
  required Widget child,
  bool disableAnimations = false,
  bool accessibleNavigation = false,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: disableAnimations,
        accessibleNavigation: accessibleNavigation,
      ),
      child: Scaffold(
        body: DefaultTextStyle(
          style: const TextStyle(color: Color(0xFF1F2A44), fontSize: 14),
          child: child,
        ),
      ),
    ),
  );
}

Text _captionText(WidgetTester tester) {
  return tester.widget<Text>(find.descendant(
    of: find.byType(CaptionFade),
    matching: find.byType(Text),
  ));
}

List<TextSpan> _captionSpans(WidgetTester tester) {
  final InlineSpan span = _captionText(tester).textSpan!;
  return (span as TextSpan).children!.cast<TextSpan>();
}

String _renderedText(WidgetTester tester) {
  final Text widget = _captionText(tester);
  if (widget.textSpan != null) return widget.textSpan!.toPlainText();
  return widget.data ?? '';
}

void main() {
  group('CaptionFade', () {
    testWidgets(
      'fades in word-by-word when Reduce Motion is off',
      (WidgetTester tester) async {
        await tester.pumpWidget(_harness(
          child: const CaptionFade(text: 'Hello world'),
        ));

        // Right after mount: both words are still at opacity ≈ 0 — the
        // first word's fade is about to begin, the second is staggered
        // behind it by wordDuration.
        final List<TextSpan> initial = _captionSpans(tester);
        expect(initial, hasLength(2));
        expect(initial[0].style!.color!.a, closeTo(0.0, 0.05));
        expect(initial[1].style!.color!.a, closeTo(0.0, 0.05));

        // Halfway through the first word's fade.
        await tester.pump(const Duration(milliseconds: 60));
        final List<TextSpan> midFirst = _captionSpans(tester);
        expect(midFirst[0].style!.color!.a, greaterThan(0.3));
        expect(midFirst[0].style!.color!.a, lessThan(0.7));
        // Second word still parked behind the stagger.
        expect(midFirst[1].style!.color!.a, closeTo(0.0, 0.05));

        // After another 120ms: first word fully visible, second word in
        // the middle of its fade.
        await tester.pump(const Duration(milliseconds: 120));
        final List<TextSpan> midSecond = _captionSpans(tester);
        expect(midSecond[0].style!.color!.a, closeTo(1.0, 0.05));
        expect(midSecond[1].style!.color!.a, greaterThan(0.3));
        expect(midSecond[1].style!.color!.a, lessThan(0.7));
      },
    );

    testWidgets(
      'renders instantly when MediaQuery.disableAnimations is set',
      (WidgetTester tester) async {
        await tester.pumpWidget(_harness(
          child: const CaptionFade(text: 'Hello world'),
          disableAnimations: true,
        ));

        final Text rendered = _captionText(tester);
        // Reduce-motion path takes the plain-Text branch, so the data
        // field is populated and there's no rich span to fade.
        expect(rendered.data, 'Hello world');
        expect(rendered.textSpan, isNull);
      },
    );

    testWidgets(
      'renders instantly when MediaQuery.accessibleNavigation is set',
      (WidgetTester tester) async {
        await tester.pumpWidget(_harness(
          child: const CaptionFade(text: 'Hello world'),
          accessibleNavigation: true,
        ));

        final Text rendered = _captionText(tester);
        expect(rendered.data, 'Hello world');
        expect(rendered.textSpan, isNull);
      },
    );

    testWidgets(
      'final state matches the input string',
      (WidgetTester tester) async {
        const String input =
            'Try saying this aloud while you sit beside her.';
        await tester.pumpWidget(_harness(
          child: const CaptionFade(text: input),
        ));

        // The ticker stops once every word has reached full opacity, so
        // pumpAndSettle converges.
        await tester.pumpAndSettle();

        expect(_renderedText(tester), input);
      },
    );

    testWidgets(
      'reveals new words from stream emissions without re-fading old ones',
      (WidgetTester tester) async {
        final StreamController<String> ctrl =
            StreamController<String>(sync: false);
        addTearDown(ctrl.close);

        await tester.pumpWidget(_harness(
          child: CaptionFade(text: '', stream: ctrl.stream),
        ));

        ctrl.add('Hello');
        // First pump drains the microtask that delivers the stream event,
        // then settle the per-word fade.
        await tester.pump();
        await tester.pumpAndSettle();
        expect(_renderedText(tester), 'Hello');

        // The "Hello" span keeps its already-faded-in state; only the
        // new "world" token kicks off a fresh fade.
        final TextSpan helloBefore = _captionSpans(tester)[0];
        expect(helloBefore.style!.color!.a, closeTo(1.0, 0.05));

        ctrl.add('Hello world');
        await tester.pump();
        // Mid-fade snapshot: "world" should still be ramping up while
        // "Hello" stays at full opacity.
        await tester.pump(const Duration(milliseconds: 30));
        final List<TextSpan> midStream = _captionSpans(tester);
        expect(midStream, hasLength(2));
        expect(midStream[0].style!.color!.a, closeTo(1.0, 0.05));
        expect(midStream[1].style!.color!.a, lessThan(0.7));

        await tester.pumpAndSettle();
        expect(_renderedText(tester), 'Hello world');
      },
    );

    testWidgets(
      'switching from animating to Reduce Motion mid-flight reveals everything',
      (WidgetTester tester) async {
        // Start under normal motion so the fade begins.
        final ValueNotifier<bool> reduce = ValueNotifier<bool>(false);
        addTearDown(reduce.dispose);

        await tester.pumpWidget(MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: reduce,
            builder: (BuildContext context, bool value, Widget? _) {
              return MediaQuery(
                data: MediaQueryData(disableAnimations: value),
                child: const Scaffold(
                  body: DefaultTextStyle(
                    style: TextStyle(color: Color(0xFF1F2A44), fontSize: 14),
                    child: CaptionFade(text: 'Hello world'),
                  ),
                ),
              );
            },
          ),
        ));

        // Briefly in the middle of the first word's fade.
        await tester.pump(const Duration(milliseconds: 30));
        expect(_captionSpans(tester)[0].style!.color!.a, lessThan(0.7));

        // Flip Reduce Motion on — the widget should swap to the plain
        // Text branch and show the full string immediately.
        reduce.value = true;
        await tester.pump();
        expect(_captionText(tester).data, 'Hello world');
      },
    );
  });
}

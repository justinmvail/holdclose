import 'package:alchemist/alchemist.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/catch_me_up_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The recap the populated golden renders — a warm, plain-language recap
/// of the day in the family vocabulary, no exclamation marks.
const String _summary =
    'Over the last day, things have been mostly steady. You logged a '
    'late-afternoon moment when your loved one got upset, and the gentle '
    'approach you tried seemed to settle it. Medications stayed on track, '
    'and there is a visit with the doctor coming up on the calendar.';

/// Hosts the card at a phone width with the summary pre-resolved to
/// [summary] so the golden render stays deterministic. No `theme:` is
/// passed — per `flutter_test_config.dart` goldens avoid dragging
/// google_fonts through the framework; the card pulls its brand colors
/// directly off `careblazersColors`.
Widget _host(String summary, double height) => ProviderScope(
      overrides: <Override>[
        catchMeUpProvider.overrideWith(() => _StubCatchMeUp(summary)),
      ],
      child: SizedBox(
        width: 390,
        height: height,
        child: MaterialApp(
          home: ColoredBox(
            color: careblazersColors.background,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: CatchMeUpCard(),
            ),
          ),
        ),
      ),
    );

/// Resolves [catchMeUpProvider] synchronously to a fixed summary so the
/// golden never streams or touches shared_preferences.
class _StubCatchMeUp extends CatchMeUp {
  _StubCatchMeUp(this._summary);

  final String _summary;

  @override
  Future<String> build() async => _summary;
}

void main() {
  group('CatchMeUpCard golden', () {
    goldenTest(
      'populated — streamed recap with refresh action',
      fileName: 'catch_me_up_card_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 14.12)',
            child: _host(_summary, 340),
          ),
        ],
      ),
    );
  });
}

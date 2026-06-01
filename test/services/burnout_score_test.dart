import 'package:careblazers/seed/support_content.dart';
import 'package:careblazers/services/burnout_score.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a 10-item answer list where every item is [value].
List<int> _uniform(int value) =>
    List<int>.filled(burnoutQuestions.length, value);

/// Build an answer list summing to [target] by spreading the remainder
/// across the first few items (each clamped to 1–5). Used to land a score
/// exactly on a band boundary.
List<int> _summingTo(int target) {
  final List<int> answers = _uniform(minAnswer); // sums to 10
  int remaining = target - minScore;
  int i = 0;
  while (remaining > 0) {
    final int room = maxAnswer - answers[i];
    final int add = remaining < room ? remaining : room;
    answers[i] += add;
    remaining -= add;
    i++;
  }
  return answers;
}

void main() {
  group('scoreBurnout — bands', () {
    test('all-minimum answers score low', () {
      final BurnoutResult result = scoreBurnout(_uniform(1));
      expect(result.score, 10);
      expect(result.band, BurnoutBand.low);
      expect(result.headline, 'Holding steady');
      expect(result.message, isNotEmpty);
    });

    test('mid-low answers stay in the low band (< 20)', () {
      final BurnoutResult result = scoreBurnout(_summingTo(19));
      expect(result.score, 19);
      expect(result.band, BurnoutBand.low);
    });

    test('score of exactly 20 crosses into moderate', () {
      final BurnoutResult result = scoreBurnout(_summingTo(20));
      expect(result.score, 20);
      expect(result.band, BurnoutBand.moderate);
      expect(result.headline, 'Running low');
    });

    test('all-2 answers score moderate', () {
      final BurnoutResult result = scoreBurnout(_uniform(2));
      expect(result.score, 20);
      expect(result.band, BurnoutBand.moderate);
    });

    test('top of the moderate band is 29', () {
      final BurnoutResult result = scoreBurnout(_summingTo(29));
      expect(result.score, 29);
      expect(result.band, BurnoutBand.moderate);
    });

    test('score of exactly 30 crosses into high', () {
      final BurnoutResult result = scoreBurnout(_summingTo(30));
      expect(result.score, 30);
      expect(result.band, BurnoutBand.high);
      expect(result.headline, 'Stretched thin');
    });

    test('all-3 answers score high', () {
      final BurnoutResult result = scoreBurnout(_uniform(3));
      expect(result.score, 30);
      expect(result.band, BurnoutBand.high);
    });

    test('top of the high band is 39', () {
      final BurnoutResult result = scoreBurnout(_summingTo(39));
      expect(result.score, 39);
      expect(result.band, BurnoutBand.high);
    });

    test('score of exactly 40 crosses into severe', () {
      final BurnoutResult result = scoreBurnout(_summingTo(40));
      expect(result.score, 40);
      expect(result.band, BurnoutBand.severe);
      expect(result.headline, 'Running on empty');
    });

    test('all-maximum answers score severe', () {
      final BurnoutResult result = scoreBurnout(_uniform(5));
      expect(result.score, 50);
      expect(result.band, BurnoutBand.severe);
    });

    test('the severe message points to professional help', () {
      final BurnoutResult result = scoreBurnout(_uniform(5));
      expect(result.message.toLowerCase(), contains('doctor'));
    });
  });

  group('scoreBurnout — validation', () {
    test('rejects a wrong answer count', () {
      expect(
        () => scoreBurnout(<int>[1, 2, 3]),
        throwsArgumentError,
      );
    });

    test('rejects a rating below the scale', () {
      final List<int> answers = _uniform(1)..[0] = 0;
      expect(() => scoreBurnout(answers), throwsArgumentError);
    });

    test('rejects a rating above the scale', () {
      final List<int> answers = _uniform(1)..[0] = 6;
      expect(() => scoreBurnout(answers), throwsArgumentError);
    });
  });

  group('BurnoutResult — value semantics', () {
    test('equal scores produce equal results', () {
      expect(scoreBurnout(_uniform(3)), scoreBurnout(_uniform(3)));
      expect(
        scoreBurnout(_uniform(3)).hashCode,
        scoreBurnout(_uniform(3)).hashCode,
      );
    });
  });

  group('support_content seed', () {
    test('the self-check has 10 questions and a 5-point scale', () {
      expect(burnoutQuestions, hasLength(10));
      expect(burnoutScaleLabels, hasLength(5));
    });

    test('every respite resource has at least one launch target', () {
      for (final RespiteResource resource in respiteResources) {
        expect(
          resource.phone != null || resource.url != null,
          isTrue,
          reason: '${resource.id} should be dialable or linkable',
        );
      }
    });

    test('phoneUri strips formatting to a tel: link', () {
      const RespiteResource resource = RespiteResource(
        id: 'x',
        name: 'Test',
        description: 'd',
        phone: '1-800-272-3900',
      );
      expect(resource.phoneUri, Uri.parse('tel:18002723900'));
    });
  });
}

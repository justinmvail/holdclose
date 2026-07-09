import 'package:holdclose/services/crisis_keywords.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('messageTriggersCrisis', () {
    test('matches a suicidality phrase (case-insensitive, mid-sentence)', () {
      expect(messageTriggersCrisis('honestly I just want to die'), isTrue);
      expect(messageTriggersCrisis('Some days I WANT TO DIE'), isTrue);
      expect(messageTriggersCrisis('I feel suicidal tonight'), isTrue);
    });

    test('matches a self-harm phrase', () {
      expect(messageTriggersCrisis('I keep thinking about hurt myself'),
          isTrue);
      expect(messageTriggersCrisis('what if I overdose on her pills'), isTrue);
    });

    test('matches a severe-abuse phrase', () {
      expect(messageTriggersCrisis('I hit her when she screamed'), isTrue);
      expect(messageTriggersCrisis('he hit me again today'), isTrue);
    });

    test('an ordinary caregiving message does NOT match', () {
      expect(
        messageTriggersCrisis('How do I get her to eat more at dinner?'),
        isFalse,
      );
      // Deliberately NOT flagged — over-broad terms would drown the card.
      expect(messageTriggersCrisis("I'm so tired and feel alone"), isFalse);
      // Medical-context "overdose" without "on" / "cut" his pills stays clear.
      expect(messageTriggersCrisis('the pharmacist warned about overdose'),
          isFalse);
    });

    test('blank / whitespace never matches', () {
      expect(messageTriggersCrisis(''), isFalse);
      expect(messageTriggersCrisis('   '), isFalse);
    });
  });

  group('firstCrisisMatch', () {
    test('returns the matched keyword with its category', () {
      final CrisisKeyword? m = firstCrisisMatch('I want to die');
      expect(m, isNotNull);
      expect(m!.category, CrisisKeywordCategory.suicidality);
    });

    test('returns null for a non-crisis message', () {
      expect(firstCrisisMatch('what are her morning meds'), isNull);
    });
  });

  group('crisisHotlines', () {
    test('leads with the 988 Lifeline', () {
      expect(crisisHotlines, isNotEmpty);
      expect(crisisHotlines.first.number, '988');
      expect(crisisHotlines.first.label, contains('988'));
    });
  });
}

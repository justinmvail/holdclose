import 'package:careblazers/models/triage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TriageAnswers JSON round-trip', () {
    test('round-trips a fully-answered triage', () {
      const TriageAnswers original = TriageAnswers(
        when: TriageWhen.lateAfternoonEvening,
        whatChanged: TriageWhatChanged.nothing,
        whatTried: TriageWhatTried.triedToExplain,
      );
      expect(
        TriageAnswers.fromJson(original.toJson()),
        equals(original),
      );
    });

    test('round-trips a partially-answered triage (Q1 only)', () {
      const TriageAnswers partial =
          TriageAnswers(when: TriageWhen.morning);
      final TriageAnswers parsed =
          TriageAnswers.fromJson(partial.toJson());
      expect(parsed.when, TriageWhen.morning);
      expect(parsed.whatChanged, isNull);
      expect(parsed.whatTried, isNull);
    });

    test('round-trips an empty triage (all nulls)', () {
      const TriageAnswers empty = TriageAnswers();
      expect(TriageAnswers.fromJson(empty.toJson()), equals(empty));
    });
  });

  group('Triage enums (BUILD_SPEC.md §5.3)', () {
    test('TriageWhen has 5 values', () {
      expect(TriageWhen.values, hasLength(5));
    });

    test('TriageWhatChanged has 6 values', () {
      expect(TriageWhatChanged.values, hasLength(6));
    });

    test('TriageWhatTried has 5 values', () {
      expect(TriageWhatTried.values, hasLength(5));
    });
  });
}

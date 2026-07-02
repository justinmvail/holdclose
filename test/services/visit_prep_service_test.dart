import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/services/visit_prep_service.dart';

/// Coverage for the visit-prep fake + the questions-parsing helper.
void main() {
  group('FakeVisitPrepService', () {
    test('returns a handful of canned questions', () async {
      const FakeVisitPrepService s = FakeVisitPrepService();
      final List<String>? q = await s.suggestQuestions(careContext: 'ctx');
      expect(q, isNotNull);
      expect(q!.length, greaterThanOrEqualTo(3));
    });
  });

  group('questionsFromMap', () {
    test('extracts a string list, trimming + dropping blanks/non-strings', () {
      expect(
        questionsFromMap(<String, dynamic>{
          'questions': <dynamic>[' Ask this ', '', 3, 'And this']
        }),
        <String>['Ask this', 'And this'],
      );
    });

    test('null when empty, wrong shape, or missing', () {
      expect(questionsFromMap(<String, dynamic>{'questions': <dynamic>[]}),
          isNull);
      expect(questionsFromMap(<String, dynamic>{'nope': 1}), isNull);
      expect(questionsFromMap(null), isNull);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/seed/provider_search_reference.dart';

void main() {
  group('normalizeStateCode', () {
    test('bare 2-letter code (any case) resolves', () {
      expect(normalizeStateCode('sc'), 'SC');
      expect(normalizeStateCode('NY'), 'NY');
    });

    test('full state name resolves to code', () {
      expect(normalizeStateCode('South Carolina'), 'SC');
      expect(normalizeStateCode('new york'), 'NY');
    });

    test('combined suggestion label resolves to trailing code', () {
      expect(normalizeStateCode('South Carolina — SC'), 'SC');
    });

    test('unknown / empty input yields empty string', () {
      expect(normalizeStateCode(''), '');
      expect(normalizeStateCode('   '), '');
      expect(normalizeStateCode('Nowhereland'), '');
    });

    test('does not false-match a random 2-letter token', () {
      // 'zz' is not a real code, so nothing resolves.
      expect(normalizeStateCode('zz'), '');
    });
  });

  group('reference lists', () {
    test('states cover 50 states + DC + PR', () {
      expect(usStates.length, 52);
      expect(usStates.map((UsState s) => s.code), contains('DC'));
    });

    test('stateLabel formats "Name — CODE"', () {
      final UsState sc =
          usStates.firstWhere((UsState s) => s.code == 'SC');
      expect(stateLabel(sc), 'South Carolina — SC');
    });

    test('specialties include common ones', () {
      expect(clinicianSpecialties, contains('Neurology'));
      expect(clinicianSpecialties, contains('Family Medicine'));
    });

    test('cities carry a valid state code', () {
      final Set<String> codes =
          usStates.map((UsState s) => s.code).toSet();
      for (final UsCity c in majorUsCities) {
        expect(codes.contains(c.state), isTrue,
            reason: '${c.name} has unknown state ${c.state}');
      }
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/document.dart';
import 'package:holdclose/services/insurance_card_scanner.dart';

/// Coverage for the insurance-card scanner's fake + the map→Insurance parser.
void main() {
  group('FakeInsuranceCardScanner', () {
    test('returns a filled Insurance', () async {
      const FakeInsuranceCardScanner s = FakeInsuranceCardScanner();
      final Insurance? ins = await s.extractFromImage(imagePath: 'x.jpg');
      expect(ins, isNotNull);
      expect(ins!.carrier, isNotEmpty);
      expect(ins.phone, isNotNull);
    });
  });

  group('insuranceFromMap', () {
    test('builds from fields + synonyms', () {
      final Insurance? ins = insuranceFromMap(<String, dynamic>{
        'carrier': 'BCBS',
        'memberId': 'M1',
        'group_number': 'G1',
        'phone': '800-555-0000',
      });
      expect(ins, isNotNull);
      expect(ins!.carrier, 'BCBS');
      expect(ins.policyNumber, 'M1');
      expect(ins.groupNumber, 'G1');
      expect(ins.phone, '800-555-0000');
    });

    test('null when all blank/missing; empty strings for partial reads', () {
      expect(
          insuranceFromMap(<String, dynamic>{'carrier': '', 'phone': ''}),
          isNull);
      expect(insuranceFromMap(null), isNull);
      final Insurance? partial =
          insuranceFromMap(<String, dynamic>{'carrier': 'X'});
      expect(partial!.carrier, 'X');
      expect(partial.policyNumber, '');
      expect(partial.phone, isNull);
    });
  });
}

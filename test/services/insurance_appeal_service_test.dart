import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/services/insurance_appeal_service.dart';

/// Coverage for the insurance-appeal fake + the letter/prompt helpers.
void main() {
  group('FakeInsuranceAppealService', () {
    test('drafts a letter naming the claim + carrier', () async {
      const FakeInsuranceAppealService s = FakeInsuranceAppealService();
      final String? letter = await s.draftAppeal(
        denialReason: 'not medically necessary',
        claimDetails: 'physical therapy sessions',
        carrier: 'BlueCross',
      );
      expect(letter, isNotNull);
      expect(letter!, contains('physical therapy sessions'));
      expect(letter, contains('BlueCross'));
    });
  });

  group('letterFromMap', () {
    test('extracts + trims the letter; null on blank/wrong/missing', () {
      expect(letterFromMap(<String, dynamic>{'letter': '  Dear …  '}), 'Dear …');
      expect(letterFromMap(<String, dynamic>{'letter': '   '}), isNull);
      expect(letterFromMap(<String, dynamic>{'nope': 1}), isNull);
      expect(letterFromMap(null), isNull);
    });
  });

  group('appealUserPrompt', () {
    test('includes carrier, patient, claim, and denial reason', () {
      final String p = appealUserPrompt(
        denialReason: 'REASON',
        claimDetails: 'CLAIM',
        carrier: 'CARRIER',
        patientName: 'PATIENT',
      );
      expect(p, contains('CARRIER'));
      expect(p, contains('PATIENT'));
      expect(p, contains('CLAIM'));
      expect(p, contains('REASON'));
    });
  });
}

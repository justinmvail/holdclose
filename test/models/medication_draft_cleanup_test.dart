import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/medication_draft.dart';

/// Pharmacy labels print "IBUPROFEN 400 MG TABLET", and the vision model copies
/// that verbatim — so the scan review offered a medication NAMED
/// "IBUPROFEN 400 MG TABLET" with a dose of "400 MG TABLET". Reported
/// 2026-07-13: "Medication didn't import correctly."
///
/// The draft now reads like something a caregiver would have typed.
void main() {
  MedicationDraft draft(Map<String, dynamic> json) =>
      MedicationDraft.fromModelJson(json);

  group('the name is the DRUG, not the whole label line', () {
    test('strength and form are stripped, SHOUTING is calmed', () {
      final MedicationDraft d = draft(<String, dynamic>{
        'name': 'IBUPROFEN 400 MG TABLET',
        'dosage': '400 MG TABLET',
      });
      expect(d.name, 'Ibuprofen');
      expect(d.dosage, '400 mg');
    });

    test('handles the shapes labels actually print', () {
      expect(draft(<String, dynamic>{'name': 'DONEPEZIL HCL 10MG TAB'}).name,
          'Donepezil Hcl');
      expect(draft(<String, dynamic>{'name': 'Amoxicillin 500 mg capsules'}).name,
          'Amoxicillin');
      expect(draft(<String, dynamic>{'name': 'Lisinopril'}).name, 'Lisinopril');
      expect(draft(<String, dynamic>{'name': 'Insulin glargine 100 units/mL'}).name,
          'Insulin glargine');
    });

    test('a name with no strength or form is left alone (mixed case kept)', () {
      expect(draft(<String, dynamic>{'name': 'Vitamin D'}).name, 'Vitamin D');
    });
  });

  group('the dosage is the STRENGTH', () {
    test('the form is dropped and the unit normalised', () {
      expect(draft(<String, dynamic>{'dosage': '400 MG TABLET'}).dosage, '400 mg');
      expect(draft(<String, dynamic>{'dosage': '10MG'}).dosage, '10 mg');
      expect(draft(<String, dynamic>{'dosage': '5 ML'}).dosage, '5 mL');
    });

    test('a non-strength dose is passed through as printed', () {
      // "1 tablet" is a legitimate dose the caregiver should see verbatim.
      expect(draft(<String, dynamic>{'dosage': '1 tablet'}).dosage, '1 tablet');
    });
  });
}

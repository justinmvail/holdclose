import 'package:careblazers/models/patient.dart';
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('maryHenderson seed — BUILD_SPEC.md §9.1', () {
    test('top-level identity fields match the spec verbatim', () {
      final Patient mary = maryHenderson();
      expect(mary.id, 'demo-patient-mary');
      expect(mary.name, 'Mary Henderson');
      expect(mary.age, 78);
      expect(mary.diagnosis, "Alzheimer's disease, stage 5 (moderately severe)");
      expect(mary.diagnosedAt, DateTime.utc(2022, 4, 15));
    });

    test('carries the three §9.1 medications in spec order', () {
      final List<Medication> meds = maryHenderson().medications;
      expect(meds, hasLength(3));
      expect(
        meds,
        containsAllInOrder(const <Medication>[
          Medication(
            name: 'Donepezil',
            dose: '10 mg',
            schedule: 'every morning',
          ),
          Medication(
            name: 'Memantine',
            dose: '10 mg',
            schedule: 'every evening',
          ),
          Medication(
            name: 'Sertraline',
            dose: '50 mg',
            schedule: 'every morning',
          ),
        ]),
      );
    });

    test('lists Penicillin as the sole allergy', () {
      expect(maryHenderson().allergies, const <String>['Penicillin']);
    });

    test('exposes the three canonical §9.1 calms', () {
      final List<String> calms = maryHenderson().calms;
      expect(calms, hasLength(3));
      expect(
        calms,
        const <String>[
          'Sitting on her left side (she hears better there).',
          'The phrase "Mom, it\'s okay."',
          'Showing her a photo of Dad (passed 2019).',
        ],
      );
    });

    test('exposes the three canonical §9.1 escalates', () {
      final List<String> escalates = maryHenderson().escalates;
      expect(escalates, hasLength(3));
      expect(
        escalates,
        const <String>[
          'Strangers leaning over her.',
          'Loud beeping (monitors, alarms).',
          'Being asked many questions in a row.',
        ],
      );
    });

    test('primary caregiver + healthcare POA both point at Sarah Henderson',
        () {
      final Patient mary = maryHenderson();
      const Contact expected = Contact(
        name: 'Sarah Henderson',
        phone: '(415) 555-0142',
      );
      expect(mary.primaryCaregiver, expected);
      expect(mary.healthcarePOA, expected);
    });

    test('advance directive is on file at Marin General, no DNR', () {
      final AdvanceDirectiveStatus ad = maryHenderson().advanceDirective;
      expect(ad.onFileAt, 'Marin General Hospital');
      expect(ad.dnr, isFalse);
    });

    test('round-trips through json without losing fields', () {
      final Patient mary = maryHenderson();
      expect(Patient.fromJson(mary.toJson()), mary);
    });

    test('is a pure function — successive calls produce equal patients', () {
      expect(maryHenderson(), maryHenderson());
    });
  });
}

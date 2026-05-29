import 'package:careblazers/models/patient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Patient maryHenderson() => Patient(
        id: 'demo-patient-mary',
        name: 'Mary Henderson',
        age: 78,
        diagnosis: "Alzheimer's disease, stage 5 (moderately severe)",
        diagnosedAt: DateTime.utc(2022, 4, 15),
        medications: const <Medication>[
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
        ],
        allergies: const <String>['Penicillin'],
        calms: const <String>[
          'Sitting on her left side.',
          "The phrase \"Mom, it's okay.\"",
        ],
        escalates: const <String>[
          'Strangers leaning over her.',
        ],
        primaryCaregiver: const Contact(
          name: 'Sarah Henderson',
          phone: '(415) 555-0142',
        ),
        healthcarePOA: const Contact(
          name: 'Sarah Henderson',
          phone: '(415) 555-0142',
        ),
        advanceDirective: const AdvanceDirectiveStatus(
          onFileAt: 'Marin General Hospital',
          dnr: false,
        ),
      );

  group('Medication JSON round-trip', () {
    test('round-trips', () {
      const Medication m = Medication(
        name: 'Sertraline',
        dose: '50 mg',
        schedule: 'every morning',
      );
      expect(Medication.fromJson(m.toJson()), equals(m));
    });
  });

  group('Contact JSON round-trip', () {
    test('round-trips', () {
      const Contact c = Contact(
        name: 'Sarah Henderson',
        phone: '(415) 555-0142',
      );
      expect(Contact.fromJson(c.toJson()), equals(c));
    });
  });

  group('AdvanceDirectiveStatus JSON round-trip', () {
    test('round-trips with dnr=false', () {
      const AdvanceDirectiveStatus s = AdvanceDirectiveStatus(
        onFileAt: 'Marin General Hospital',
        dnr: false,
      );
      expect(AdvanceDirectiveStatus.fromJson(s.toJson()), equals(s));
    });

    test('round-trips with dnr=true', () {
      const AdvanceDirectiveStatus s = AdvanceDirectiveStatus(
        onFileAt: 'UCSF',
        dnr: true,
      );
      expect(AdvanceDirectiveStatus.fromJson(s.toJson()), equals(s));
    });
  });

  group('Patient JSON round-trip', () {
    test('round-trips the Mary Henderson seed shape (BUILD_SPEC.md §9.1)',
        () {
      final Patient mary = maryHenderson();
      expect(Patient.fromJson(mary.toJson()), equals(mary));
    });
  });
}

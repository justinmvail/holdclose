import 'package:holdclose/models/patient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Patient maryHenderson() => Patient(
        id: 'demo-patient-mary',
        name: 'Mary Henderson',
        age: 78,
        diagnosis: "Alzheimer's disease, stage 5 (moderately severe)",
        diagnosedAt: DateTime.utc(2022, 4, 15),
        medications: const <CrisisMedication>[
          CrisisMedication(
            name: 'Donepezil',
            dose: '10 mg',
            schedule: 'every morning',
          ),
          CrisisMedication(
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

  group('CrisisMedication JSON round-trip', () {
    test('round-trips', () {
      const CrisisMedication m = CrisisMedication(
        name: 'Sertraline',
        dose: '50 mg',
        schedule: 'every morning',
      );
      expect(CrisisMedication.fromJson(m.toJson()), equals(m));
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

    test('round-trips with a date of birth on file', () {
      final Patient mary = maryHenderson().copyWith(
        dateOfBirth: DateTime.utc(1948, 3, 4),
      );
      final Patient back = Patient.fromJson(mary.toJson());
      expect(back, equals(mary));
      expect(back.dateOfBirth, DateTime.utc(1948, 3, 4));
    });

    test('round-trips with dateOfBirth null (pre-DOB profiles)', () {
      // Rows persisted before the field existed deserialize with null —
      // the patients table stores the whole model as a JSON blob.
      final Patient mary = maryHenderson();
      expect(mary.dateOfBirth, isNull);
      final Patient back = Patient.fromJson(mary.toJson());
      expect(back.dateOfBirth, isNull);
      expect(back, equals(mary));
    });
  });

  group('PatientX.ageOn', () {
    test('derives the age from dateOfBirth when set', () {
      final Patient p = maryHenderson().copyWith(
        dateOfBirth: DateTime.utc(1948, 3, 4),
      );
      // Birthday already passed in the as-of year.
      expect(p.ageOn(DateTime(2026, 7, 8)), 78);
      // Birthday not yet reached in the as-of year.
      expect(p.ageOn(DateTime(2026, 3, 3)), 77);
      // On the birthday itself.
      expect(p.ageOn(DateTime(2026, 3, 4)), 78);
    });

    test('falls back to the stored age without a dateOfBirth', () {
      final Patient p = maryHenderson();
      expect(p.dateOfBirth, isNull);
      expect(p.ageOn(DateTime(2030, 1, 1)), p.age);
    });

    test('ageFromDateOfBirth clamps a future birth date at 0', () {
      expect(
        ageFromDateOfBirth(DateTime(2030, 1, 1), DateTime(2026, 1, 1)),
        0,
      );
    });
  });
}

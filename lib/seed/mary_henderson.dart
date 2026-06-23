import '../models/patient.dart';

/// The demo loved one's profile (BUILD_SPEC.md §9.1).
///
/// Loaded into the crisis card on first launch when the storage layer
/// has no Patient yet AND the build is in `DEMO_MODE`. Real-mode builds
/// start the crisis card on an empty placeholder and let the caregiver
/// fill it in inline.
///
/// The shape mirrors §9.1 verbatim so a test that re-reads §9.1 stays
/// in sync with the seed. Kept const-buildable everywhere except
/// [diagnosedAt] (DateTime is not const) — wrapped in a function so
/// the [DateTime] is constructed fresh per call and the seed remains
/// equality-safe across the JSON round-trip.
Patient maryHenderson() => Patient(
      id: 'demo-patient-mary',
      name: 'Mary Henderson',
      age: 78,
      diagnosis: 'Stroke recovery (ischemic, 2024); high blood pressure',
      diagnosedAt: DateTime.utc(2024, 2, 10),
      medications: const <CrisisMedication>[
        CrisisMedication(
          name: 'Lisinopril',
          dose: '10 mg',
          schedule: 'every morning',
        ),
        CrisisMedication(
          name: 'Atorvastatin',
          dose: '20 mg',
          schedule: 'every evening',
        ),
        CrisisMedication(
          name: 'Aspirin',
          dose: '81 mg',
          schedule: 'every morning',
        ),
      ],
      allergies: const <String>['Penicillin'],
      calms: const <String>[
        'Sitting on her left side (she hears better there).',
        'The phrase "Mom, it\'s okay."',
        'Looking through the family photo album together.',
      ],
      escalates: const <String>[
        'Strangers leaning over her.',
        'Loud beeping (monitors, alarms).',
        'Being rushed or hurried through things.',
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

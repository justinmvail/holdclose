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
        Medication(
          name: 'Sertraline',
          dose: '50 mg',
          schedule: 'every morning',
        ),
      ],
      allergies: const <String>['Penicillin'],
      calms: const <String>[
        'Sitting on her left side (she hears better there).',
        'The phrase "Mom, it\'s okay."',
        'Showing her a photo of Dad (passed 2019).',
      ],
      escalates: const <String>[
        'Strangers leaning over her.',
        'Loud beeping (monitors, alarms).',
        'Being asked many questions in a row.',
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

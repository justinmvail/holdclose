import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/document.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medical/emergency_card_screen.dart';
import 'package:careblazers/screens/medication/medication_list_screen.dart'
    show MedicationListItem;
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

EmergencyCardView _populated() => EmergencyCardView(
      patient: maryHenderson(),
      card: EmergencyCard(
        id: 'ec-1',
        patientId: maryHenderson().id,
        updatedAt: DateTime.utc(2026, 5, 29),
        conditions: const <String>["Alzheimer's, stage 5", 'Hypertension'],
        medications: const <String>[],
        allergies: const <String>['Penicillin', 'Sulfa drugs'],
        emergencyContacts: const <EmergencyContact>[
          EmergencyContact(
            name: 'Sarah Henderson',
            relation: 'Daughter',
            phone: '(415) 555-0142',
          ),
        ],
        insurance: const Insurance(
          carrier: 'Medicare',
          policyNumber: '1EG4-TE5-MK72',
          groupNumber: 'GRP-0099',
        ),
        donorStatus: DonorStatus.donor,
      ),
      medications: const <MedicationListItem>[
        MedicationListItem(
          medication: Medication(
            id: 'm-donepezil',
            name: 'Donepezil',
            dosage: '10 mg',
            route: MedicationRoute.oral,
          ),
          nextDose: null,
          adherenceLast7Days: 1.0,
          hasScoreableHistory: false,
        ),
      ],
    );

EmergencyCardView _empty() => EmergencyCardView(
      patient: maryHenderson(),
      card: null,
      medications: const <MedicationListItem>[],
    );

Widget _host(EmergencyCardView view, double height) {
  return ProviderScope(
    overrides: <Override>[
      emergencyCardViewProvider.overrideWith((Ref ref) async => view),
    ],
    child: SizedBox(
      width: 420,
      height: height,
      child: MaterialApp(
        home: const EmergencyCardScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('EmergencyCardScreen golden', () {
    goldenTest(
      'renders the populated ICE card',
      fileName: 'emergency_card_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 14.23)',
            child: _host(_populated(), 1200),
          ),
        ],
      ),
    );

    goldenTest(
      'renders the empty ICE card',
      fileName: 'emergency_card_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty card (Phase 14.23)',
            child: _host(_empty(), 1000),
          ),
        ],
      ),
    );
  });
}

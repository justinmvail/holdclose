import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/document.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medical/emergency_card_screen.dart';
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override, Ref;

/// CI goldens of the read-only Emergency (ICE) Card view at
/// `/medical/cards/emergency` (BUILD_SPEC.md §5.17). Tests override
/// [emergencyCardViewProvider] wholesale with a fixed [EmergencyCardView]
/// (the documented seam) so the screen renders deterministically without
/// standing up the three drift backends it normally blends.
EmergencyCardView _populatedView() => EmergencyCardView(
      patient: maryHenderson(),
      card: EmergencyCard(
        id: 'ec-golden',
        patientId: maryHenderson().id,
        updatedAt: DateTime(2026, 6, 1),
        conditions: const <String>["Alzheimer's", 'Hypertension'],
        medications: const <String>['Donepezil 10 mg'],
        allergies: const <String>['Penicillin'],
        emergencyContacts: const <EmergencyContact>[
          EmergencyContact(
              name: 'Sarah Henderson',
              relation: 'Daughter',
              phone: '(415) 555-0142'),
        ],
        insurance: const Insurance(
            carrier: 'Medicare', policyNumber: 'P123', groupNumber: 'G9'),
        donorStatus: DonorStatus.donor,
      ),
      // The Medications section mirrors the live tracker (a flat list).
      medications: const <Medication>[
        Medication(
            id: 'm-don',
            name: 'Donepezil',
            dosage: '10 mg',
            route: MedicationRoute.oral),
        Medication(
            id: 'm-mem',
            name: 'Memantine',
            dosage: '10 mg',
            route: MedicationRoute.oral),
      ],
    );

const EmergencyCardView _emptyView = EmergencyCardView(
  patient: null,
  card: null,
  medications: <Medication>[],
);

Widget _host(EmergencyCardView view, {double height = 1600}) {
  final GoRouter router = GoRouter(
    initialLocation: '/medical/cards/emergency',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/cards/emergency',
        builder: (BuildContext context, GoRouterState state) =>
            const EmergencyCardScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      emergencyCardViewProvider.overrideWith((Ref ref) async => view),
    ],
    child: SizedBox(
      width: 420,
      height: height,
      child: MaterialApp.router(
        routerConfig: router,
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
      'populated ICE card — all sections',
      fileName: 'emergency_card_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated',
            child: _host(_populatedView()),
          ),
        ],
      ),
    );

    goldenTest(
      'empty — no loved one on file yet',
      fileName: 'emergency_card_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty placeholder',
            child: _host(_emptyView, height: 900),
          ),
        ],
      ),
    );
  });
}

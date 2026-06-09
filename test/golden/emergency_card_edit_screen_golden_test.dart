import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/document.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medical/emergency_card_edit_screen.dart';
import 'package:careblazers/screens/medical/emergency_card_screen.dart'
    show EmergencyCardView, emergencyCardViewProvider;
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

EmergencyCardView _populatedView() => EmergencyCardView(
      patient: maryHenderson(),
      card: EmergencyCard(
        id: 'ec-golden',
        patientId: maryHenderson().id,
        updatedAt: DateTime(2026, 6, 1),
        conditions: const <String>['Alzheimer\'s', 'Hypertension'],
        medications: const <String>['Donepezil 10 mg'],
        allergies: const <String>['Penicillin'],
        emergencyContacts: const <EmergencyContact>[
          EmergencyContact(
              name: 'Jane Doe', relation: 'Daughter', phone: '555-1234'),
        ],
        insurance: const Insurance(
            carrier: 'Medicare', policyNumber: 'P123', groupNumber: 'G9'),
        donorStatus: DonorStatus.donor,
      ),
      medications: const <Medication>[],
    );

void main() {
  group('EmergencyCardEditScreen golden', () {
    goldenTest(
      'populated emergency-card edit form',
      fileName: 'emergency_card_edit_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated edit form',
            child: ProviderScope(
              overrides: <Override>[
                emergencyCardViewProvider
                    .overrideWith((Ref ref) async => _populatedView()),
              ],
              child: SizedBox(
                width: 420,
                height: 1800,
                child: MaterialApp.router(
                  routerConfig: _goldenRouter(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

GoRouter _goldenRouter() {
  return GoRouter(
    initialLocation: '/medical/cards/emergency/edit',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/cards/emergency',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
        routes: <RouteBase>[
          GoRoute(
            path: 'edit',
            builder: (BuildContext context, GoRouterState state) =>
                const EmergencyCardEditScreen(),
          ),
        ],
      ),
    ],
  );
}

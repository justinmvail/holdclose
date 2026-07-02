import 'package:alchemist/alchemist.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/models/medication_draft.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/medication/medication_form_screen.dart';
import 'package:holdclose/screens/medication/medication_import_review_screen.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/theme.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 5, 30, 9, 0);

MedicationRepository _repo() {
  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  return MedicationRepository(db, clock: _fixedNow);
}

const MedicationDraft _draft = MedicationDraft(
  name: 'Lisinopril',
  dosage: '10 mg',
  route: MedicationRoute.oral,
  prescriber: 'Dr. Alvarez',
  notes: 'Take one tablet by mouth once daily.',
  rxNumber: '1687749',
  quantity: '180',
  refills: '3',
  pharmacyName: 'CVS Pharmacy',
  pharmacyPhone: '843-767-4500',
  dateFilled: '12/3/21',
  discardAfter: '12/3/22',
);

void main() {
  group('MedicationImportReviewScreen golden', () {
    goldenTest(
      'scanned-prescription review, pre-filled from the AI draft',
      fileName: 'medication_import_review_screen_prefilled',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'review + approve (AI scan → human-in-the-loop)',
            child: ProviderScope(
              overrides: <Override>[
                medicationRepositoryBackendProvider.overrideWithValue(_repo()),
                medicationFormIdFactoryProvider
                    .overrideWithValue(() => 'golden-id'),
                storageBackendProvider
                    .overrideWithValue(InMemoryStorageProvider()),
              ],
              child: SizedBox(
                width: 420,
                height: 2000,
                child: MaterialApp.router(
                  routerConfig: _goldenRouter(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: holdcloseColors.background,
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
    initialLocation: '/medications/scan/review',
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
        routes: <RouteBase>[
          GoRoute(
            path: 'scan/review',
            builder: (BuildContext context, GoRouterState state) =>
                const MedicationImportReviewScreen(draft: _draft),
          ),
        ],
      ),
    ],
  );
}

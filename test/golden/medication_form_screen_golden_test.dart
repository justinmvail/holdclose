import 'package:alchemist/alchemist.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/medication/medication_form_screen.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 5, 30, 9, 0);

MedicationRepository _repo() {
  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  return MedicationRepository(db, clock: _fixedNow);
}

void main() {
  group('MedicationFormScreen golden', () {
    goldenTest(
      'empty add-medication form',
      fileName: 'medication_form_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty form (Phase 12.3)',
            child: ProviderScope(
              overrides: <Override>[
                medicationRepositoryBackendProvider.overrideWithValue(_repo()),
                medicationFormClockProvider.overrideWithValue(_fixedNow),
                medicationFormIdFactoryProvider
                    .overrideWithValue(() => 'golden-id'),
                // The window multi-select reads doseWindowListProvider,
                // which resolves its patient id via activePatientIdProvider
                // → storageProvider; an empty in-memory store keeps the
                // golden off on-device sqlite. The repo has no windows so
                // the rendered form is unchanged.
                storageBackendProvider
                    .overrideWithValue(InMemoryStorageProvider()),
              ],
              child: SizedBox(
                width: 420,
                height: 1900,
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
    initialLocation: '/medications/new',
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            builder: (BuildContext context, GoRouterState state) =>
                const MedicationFormScreen(),
          ),
        ],
      ),
    ],
  );
}

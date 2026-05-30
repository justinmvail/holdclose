import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/screens/medication/medication_form_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 5, 30, 9, 0);

MedicationRepository _repo() {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
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
              ],
              child: SizedBox(
                width: 420,
                height: 1100,
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

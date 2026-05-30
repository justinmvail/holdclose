import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medication/medication_list_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 5, 30, 6, 0);

MedicationRepository _emptyRepo() {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  return MedicationRepository(db, clock: _fixedNow);
}

Future<MedicationRepository> _populatedRepo() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final MedicationRepository repo =
      MedicationRepository(db, clock: _fixedNow);

  await repo.upsertMedication(const Medication(
    id: 'med-donepezil',
    name: 'Donepezil',
    dosage: '10 mg',
    route: MedicationRoute.oral,
    prescriber: 'Dr. Kim',
  ));
  await repo.upsertSchedule(DoseSchedule(
    id: 'sched-donepezil',
    medicationId: 'med-donepezil',
    frequencyKind: FrequencyKind.daily,
    timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
    daysOfWeek: const <int>{},
    startsOn: DateTime(2026, 5, 1),
  ));
  // Three taken doses in the trailing window → strong adherence chip.
  for (int day = 27; day <= 29; day++) {
    await repo.upsertDoseLog(DoseLog(
      id: 'log-don-$day',
      medicationId: 'med-donepezil',
      scheduledFor: DateTime(2026, 5, day, 8),
      takenAt: DateTime(2026, 5, day, 8, 2),
      status: DoseStatus.taken,
    ));
  }

  await repo.upsertMedication(const Medication(
    id: 'med-memantine',
    name: 'Memantine',
    dosage: '10 mg',
    route: MedicationRoute.oral,
  ));
  await repo.upsertSchedule(DoseSchedule(
    id: 'sched-memantine',
    medicationId: 'med-memantine',
    frequencyKind: FrequencyKind.daily,
    timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 20, minute: 0)],
    daysOfWeek: const <int>{},
    startsOn: DateTime(2026, 5, 1),
  ));

  await repo.upsertMedication(const Medication(
    id: 'med-sertraline',
    name: 'Sertraline',
    dosage: '50 mg',
    route: MedicationRoute.oral,
    notes: 'Take with breakfast.',
  ));
  // No schedule — surfaces the "No upcoming dose" subtitle in the card.

  return repo;
}

void main() {
  group('MedicationListScreen golden', () {
    goldenTest(
      'empty state — Add medication CTA inline',
      fileName: 'medication_list_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 12.3)',
            child: ProviderScope(
              overrides: <Override>[
                medicationRepositoryBackendProvider
                    .overrideWithValue(_emptyRepo()),
                medicationListClockProvider.overrideWithValue(_fixedNow),
              ],
              child: SizedBox(
                width: 420,
                height: 900,
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

    goldenTest(
      'populated state — three medications + FAB',
      fileName: 'medication_list_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 12.3)',
            child: FutureBuilder<MedicationRepository>(
              future: _populatedRepo(),
              builder: (BuildContext context,
                  AsyncSnapshot<MedicationRepository> snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                return ProviderScope(
                  overrides: <Override>[
                    medicationRepositoryBackendProvider
                        .overrideWithValue(snapshot.data!),
                    medicationListClockProvider.overrideWithValue(_fixedNow),
                  ],
                  child: SizedBox(
                    width: 420,
                    height: 900,
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
                );
              },
            ),
          ),
        ],
      ),
    );
  });
}

GoRouter _goldenRouter() {
  return GoRouter(
    initialLocation: '/medications',
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        builder: (BuildContext context, GoRouterState state) =>
            const MedicationListScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
        ],
      ),
    ],
  );
}

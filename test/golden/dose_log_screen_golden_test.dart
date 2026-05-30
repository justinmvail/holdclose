import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 5, 30, 11, 0);

MedicationRepository _emptyRepo() {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  return MedicationRepository(db, clock: _fixedNow);
}

Future<MedicationRepository> _populatedRepo() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final MedicationRepository repo =
      MedicationRepository(db, clock: _fixedNow);

  // 8 AM Donepezil — already taken on time.
  await repo.upsertMedication(const Medication(
    id: 'med-donepezil',
    name: 'Donepezil',
    dosage: '10 mg',
    route: MedicationRoute.oral,
  ));
  await repo.upsertSchedule(DoseSchedule(
    id: 'sched-donepezil',
    medicationId: 'med-donepezil',
    frequencyKind: FrequencyKind.daily,
    timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
    daysOfWeek: const <int>{},
    startsOn: DateTime(2026, 5, 1),
  ));
  await repo.upsertDoseLog(DoseLog(
    id: 'log-don',
    medicationId: 'med-donepezil',
    scheduledFor: DateTime(2026, 5, 30, 8),
    takenAt: DateTime(2026, 5, 30, 8, 2),
    status: DoseStatus.taken,
  ));

  // 9 AM Sertraline — late badge case.
  await repo.upsertMedication(const Medication(
    id: 'med-sertraline',
    name: 'Sertraline',
    dosage: '50 mg',
    route: MedicationRoute.oral,
  ));
  await repo.upsertSchedule(DoseSchedule(
    id: 'sched-sertraline',
    medicationId: 'med-sertraline',
    frequencyKind: FrequencyKind.daily,
    timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
    daysOfWeek: const <int>{},
    startsOn: DateTime(2026, 5, 1),
  ));
  await repo.upsertDoseLog(DoseLog(
    id: 'log-sert',
    medicationId: 'med-sertraline',
    scheduledFor: DateTime(2026, 5, 30, 9),
    takenAt: DateTime(2026, 5, 30, 10, 30),
    status: DoseStatus.late,
  ));

  // 10 AM Galantamine — skipped.
  await repo.upsertMedication(const Medication(
    id: 'med-galantamine',
    name: 'Galantamine',
    dosage: '8 mg',
    route: MedicationRoute.oral,
  ));
  await repo.upsertSchedule(DoseSchedule(
    id: 'sched-galantamine',
    medicationId: 'med-galantamine',
    frequencyKind: FrequencyKind.daily,
    timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 10, minute: 0)],
    daysOfWeek: const <int>{},
    startsOn: DateTime(2026, 5, 1),
  ));
  await repo.upsertDoseLog(DoseLog(
    id: 'log-gal',
    medicationId: 'med-galantamine',
    scheduledFor: DateTime(2026, 5, 30, 10),
    status: DoseStatus.skipped,
  ));

  // 8 PM Memantine — upcoming (no log row).
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

  return repo;
}

void main() {
  group('DoseLogScreen golden', () {
    goldenTest(
      'empty state — nothing scheduled today',
      fileName: 'dose_log_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 12.4)',
            child: ProviderScope(
              overrides: <Override>[
                medicationRepositoryBackendProvider
                    .overrideWithValue(_emptyRepo()),
                doseLogClockProvider.overrideWithValue(_fixedNow),
                doseLogIdFactoryProvider
                    .overrideWithValue(() => 'golden-id'),
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
      'populated — mixed taken / late / skipped / upcoming',
      fileName: 'dose_log_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 12.4)',
            child: FutureBuilder<MedicationRepository>(
              future: _populatedRepo(),
              builder: (BuildContext context,
                  AsyncSnapshot<MedicationRepository> snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                return ProviderScope(
                  overrides: <Override>[
                    medicationRepositoryBackendProvider
                        .overrideWithValue(snapshot.data!),
                    doseLogClockProvider.overrideWithValue(_fixedNow),
                    doseLogIdFactoryProvider
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
    initialLocation: '/medications/today',
    routes: <RouteBase>[
      GoRoute(
        path: '/medications/today',
        builder: (BuildContext context, GoRouterState state) =>
            const DoseLogScreen(),
      ),
    ],
  );
}

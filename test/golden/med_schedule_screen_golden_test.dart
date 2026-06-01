import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medical/med_schedule_screen.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart'
    show doseLogClockProvider;
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Fixed "now": 11 AM Saturday May 30 2026 — so the displayed-day
/// statuses split into taken (8 AM, logged), missed (8 AM unlogged on
/// past days), and due (2 PM / 8 PM still ahead today).
DateTime _fixedNow() => DateTime(2026, 5, 30, 11, 0);

Future<MedicationRepository> _populatedRepo() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final MedicationRepository repo = MedicationRepository(db, clock: _fixedNow);

  // 8 AM Donepezil — taken on time today AND yesterday.
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
    id: 'log-don-today',
    medicationId: 'med-donepezil',
    scheduledFor: DateTime(2026, 5, 30, 8),
    takenAt: DateTime(2026, 5, 30, 8, 3),
    status: DoseStatus.taken,
  ));
  await repo.upsertDoseLog(DoseLog(
    id: 'log-don-yest',
    medicationId: 'med-donepezil',
    scheduledFor: DateTime(2026, 5, 29, 8),
    takenAt: DateTime(2026, 5, 29, 8, 5),
    status: DoseStatus.taken,
  ));

  // 2 PM Sertraline — unlogged (due today / tomorrow, missed yesterday).
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
    timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 14, minute: 0)],
    daysOfWeek: const <int>{},
    startsOn: DateTime(2026, 5, 1),
  ));

  // 8 PM Memantine — unlogged evening dose.
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

Widget _host(MedicationRepository repo) {
  final GoRouter router = GoRouter(
    initialLocation: '/medical/schedule',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/schedule',
        builder: (BuildContext context, GoRouterState state) =>
            const MedScheduleScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      medicationRepositoryBackendProvider.overrideWithValue(repo),
      doseLogClockProvider.overrideWithValue(_fixedNow),
    ],
    child: SizedBox(
      width: 420,
      height: 900,
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

/// Builds the populated host inside a FutureBuilder (the in-memory repo
/// seeds asynchronously, mirroring the dose-log golden).
Widget _populatedHost() => FutureBuilder<MedicationRepository>(
      future: _populatedRepo(),
      builder: (BuildContext context, AsyncSnapshot<MedicationRepository> s) {
        if (!s.hasData) return const SizedBox.shrink();
        return _host(s.data!);
      },
    );

/// Tap a day-cycle chip [n] times, settling around the navigation so the
/// re-queried day's markers are rendered before the golden is captured.
PumpAction _cycle(Key chip, int n) {
  return (WidgetTester tester) async {
    await tester.pumpAndSettle();
    for (int i = 0; i < n; i++) {
      await tester.tap(find.byKey(chip));
      await tester.pumpAndSettle();
    }
  };
}

void main() {
  group('MedScheduleScreen golden', () {
    goldenTest(
      'today — taken 8 AM, due 2 PM + 8 PM, now line',
      fileName: 'med_schedule_screen_today',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'today (Phase 14.20)',
            child: _populatedHost(),
          ),
        ],
      ),
    );

    goldenTest(
      'yesterday — 8 AM taken, 2 PM + 8 PM missed',
      fileName: 'med_schedule_screen_yesterday',
      pumpBeforeTest: _cycle(MedScheduleScreen.prevDayKey, 1),
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'yesterday (Phase 14.20)',
            child: _populatedHost(),
          ),
        ],
      ),
    );

    goldenTest(
      'tomorrow — all doses due',
      fileName: 'med_schedule_screen_tomorrow',
      pumpBeforeTest: _cycle(MedScheduleScreen.nextDayKey, 1),
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'tomorrow (Phase 14.20)',
            child: _populatedHost(),
          ),
        ],
      ),
    );
  });
}

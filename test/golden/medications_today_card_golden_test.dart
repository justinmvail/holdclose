import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/medications_today_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// 11 AM Sat May 30 2026 — past the morning dose, inside the 2-hour
/// due-soon window for the 12:30 PM dose, before the evening dose.
DateTime _fixedNow() => DateTime(2026, 5, 30, 11, 0);

Medication _med(String id, String name, String dosage) => Medication(
      id: id,
      name: name,
      dosage: dosage,
      route: MedicationRoute.oral,
    );

DoseSchedule _dailyAt(String id, String medId, int hour, int minute) =>
    DoseSchedule(
      id: id,
      medicationId: medId,
      frequencyKind: FrequencyKind.daily,
      timesOfDay: <TimeOfDay>[TimeOfDay(hour: hour, minute: minute)],
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 5, 1),
    );

MedicationRepository _emptyRepo() => MedicationRepository(
      CareblazersDatabase(NativeDatabase.memory()),
      clock: _fixedNow,
    );

/// Donepezil (taken), Sertraline (overdue, unlogged), Memantine
/// (due-soon, unlogged) — a partial day showing all three dot hues.
Future<MedicationRepository> _partialRepo() async {
  final MedicationRepository repo = _emptyRepo();

  await repo.upsertMedication(_med('med-don', 'Donepezil', '10 mg'));
  await repo.upsertSchedule(_dailyAt('sched-don', 'med-don', 8, 0));
  await repo.upsertDoseLog(DoseLog(
    id: 'log-don',
    medicationId: 'med-don',
    scheduledFor: DateTime(2026, 5, 30, 8),
    takenAt: DateTime(2026, 5, 30, 8, 1),
    status: DoseStatus.taken,
  ));

  await repo.upsertMedication(_med('med-sert', 'Sertraline', '50 mg'));
  await repo.upsertSchedule(_dailyAt('sched-sert', 'med-sert', 10, 0));

  await repo.upsertMedication(_med('med-mem', 'Memantine', '10 mg'));
  await repo.upsertSchedule(_dailyAt('sched-mem', 'med-mem', 12, 30));

  return repo;
}

/// Two morning doses, both taken on time — the "all taken" steady state.
Future<MedicationRepository> _allTakenRepo() async {
  final MedicationRepository repo = _emptyRepo();

  await repo.upsertMedication(_med('med-don', 'Donepezil', '10 mg'));
  await repo.upsertSchedule(_dailyAt('sched-don', 'med-don', 8, 0));
  await repo.upsertDoseLog(DoseLog(
    id: 'log-don',
    medicationId: 'med-don',
    scheduledFor: DateTime(2026, 5, 30, 8),
    takenAt: DateTime(2026, 5, 30, 8, 1),
    status: DoseStatus.taken,
  ));

  await repo.upsertMedication(_med('med-sert', 'Sertraline', '50 mg'));
  await repo.upsertSchedule(_dailyAt('sched-sert', 'med-sert', 9, 0));
  await repo.upsertDoseLog(DoseLog(
    id: 'log-sert',
    medicationId: 'med-sert',
    scheduledFor: DateTime(2026, 5, 30, 9),
    takenAt: DateTime(2026, 5, 30, 9, 2),
    status: DoseStatus.taken,
  ));

  return repo;
}

GoRouter _goldenRouter() {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) => const Scaffold(
          backgroundColor: Color(0xFFFFFFFF),
          body: Padding(
            padding: EdgeInsets.all(16),
            child: MedicationsTodayCard(),
          ),
        ),
      ),
    ],
  );
}

/// Hosts the card at a phone width on a synchronously-ready repo. No
/// `theme:` is passed — per `flutter_test_config.dart` goldens avoid
/// dragging google_fonts through the framework; the card pulls its brand
/// colors directly off `careblazersColors`.
Widget _host(MedicationRepository repo, double height) => ProviderScope(
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        doseLogClockProvider.overrideWithValue(_fixedNow),
      ],
      child: SizedBox(
        width: 390,
        height: height,
        child: MaterialApp.router(
          routerConfig: _goldenRouter(),
          builder: (BuildContext context, Widget? child) => ColoredBox(
            color: careblazersColors.background,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );

/// Builds the host once [future] resolves the populated repo.
Widget _asyncHost(Future<MedicationRepository> future, double height) =>
    FutureBuilder<MedicationRepository>(
      future: future,
      builder: (BuildContext context,
          AsyncSnapshot<MedicationRepository> snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        return _host(snapshot.data!, height);
      },
    );

void main() {
  group('MedicationsTodayCard golden', () {
    goldenTest(
      'empty — nothing scheduled today',
      fileName: 'medications_today_card_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 14.9)',
            child: _host(_emptyRepo(), 260),
          ),
        ],
      ),
    );

    goldenTest(
      'partial — taken / overdue / due-soon mix',
      fileName: 'medications_today_card_partial',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'partial (Phase 14.9)',
            child: _asyncHost(_partialRepo(), 320),
          ),
        ],
      ),
    );

    goldenTest(
      'all taken — every dose given',
      fileName: 'medications_today_card_all_taken',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'all taken (Phase 14.9)',
            child: _asyncHost(_allTakenRepo(), 280),
          ),
        ],
      ),
    );
  });
}

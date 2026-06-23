import 'package:alchemist/alchemist.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/medication/dose_log_screen.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

/// 9:00 AM on 2026-06-04. The morning (8:00) dose sits 60 min back; the
/// noon-window (9:00) dose sits at "now".
DateTime _fixedNow() => DateTime(2026, 6, 4, 9, 0);
DateTime get _noonDose => DateTime(2026, 6, 4, 9, 0);

Medication _med(String id, String name, {String dosage = '10 mg'}) =>
    Medication(id: id, name: name, dosage: dosage, route: MedicationRoute.oral);

DoseWindow _window(String id, String label, TimeOfDay anchor, int sortOrder) =>
    DoseWindow(
      id: id,
      patientId: _patientId,
      label: label,
      anchorTime: anchor,
      sortOrder: sortOrder,
    );

MedicationWindowEntry _entry(String id, String medId, String windowId) =>
    MedicationWindowEntry(
      id: id,
      medicationId: medId,
      windowId: windowId,
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 1, 1),
    );

MedicationRepository _repo() =>
    MedicationRepository(HoldcloseDatabase(NativeDatabase.memory()),
        clock: _fixedNow);

Future<MedicationRepository> _populatedRepo() async {
  final MedicationRepository repo = _repo();
  await repo.upsertWindow(
      _window('w-morning', 'Morning', const TimeOfDay(hour: 8, minute: 0), 0));
  await repo.upsertWindow(
      _window('w-noon', 'Noon', const TimeOfDay(hour: 9, minute: 0), 1));
  await repo.upsertMedication(_med('m-don', 'Donepezil', dosage: '10 mg'));
  await repo.upsertMedication(_med('m-ibu', 'Ibuprofen', dosage: '200 mg'));
  await repo.upsertEntry(_entry('e-don', 'm-don', 'w-morning'));
  await repo.upsertEntry(_entry('e-ibu', 'm-ibu', 'w-noon'));
  // Pre-log the noon dose as taken so the checklist shows one resolved row
  // (green check) alongside one still-pending morning row (+ bulk button).
  await repo.upsertDoseLog(DoseLog(
    id: 'log-seed',
    medicationId: 'm-ibu',
    scheduledFor: _noonDose,
    takenAt: _fixedNow(),
    status: DoseStatus.taken,
  ));
  return repo;
}

Widget _host(MedicationRepository repo) {
  final GoRouter router = GoRouter(
    initialLocation: '/medications/today',
    routes: <RouteBase>[
      GoRoute(
        path: '/medications/today',
        builder: (BuildContext context, GoRouterState state) =>
            const DoseLogScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      medicationRepositoryBackendProvider.overrideWithValue(repo),
      doseLogClockProvider.overrideWithValue(_fixedNow),
      doseLogIdFactoryProvider.overrideWithValue(() => 'golden-log-id'),
      storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
    ],
    child: SizedBox(
      width: 420,
      height: 900,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('DoseLogScreen golden', () {
    goldenTest(
      "today's doses — one taken, one pending (+ bulk morning)",
      fileName: 'dose_log_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated checklist',
            child: FutureBuilder<MedicationRepository>(
              future: _populatedRepo(),
              builder: (BuildContext context,
                  AsyncSnapshot<MedicationRepository> snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                return _host(snap.data!);
              },
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'empty — nothing scheduled today',
      fileName: 'dose_log_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty',
            child: _host(_repo()),
          ),
        ],
      ),
    );
  });
}

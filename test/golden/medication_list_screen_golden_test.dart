import 'package:alchemist/alchemist.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/medication/medication_list_screen.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

DateTime _fixedNow() => DateTime(2026, 6, 4, 9, 0);

Medication _med(String id, String name, {String dosage = '10 mg'}) =>
    Medication(id: id, name: name, dosage: dosage, route: MedicationRoute.oral);

DoseWindow _window(
  String id,
  String label, {
  TimeOfDay anchor = const TimeOfDay(hour: 8, minute: 0),
  int sortOrder = 0,
}) =>
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
  await repo.upsertWindow(_window('w-morning', 'Morning'));
  await repo.upsertWindow(_window('w-bed', 'Bedtime',
      anchor: const TimeOfDay(hour: 21, minute: 0), sortOrder: 1));
  await repo.upsertMedication(_med('m-don', 'Donepezil', dosage: '10 mg'));
  await repo.upsertMedication(_med('m-mem', 'Memantine', dosage: '10 mg'));
  await repo.upsertMedication(_med('m-ibu', 'Ibuprofen', dosage: '200 mg'));
  await repo.upsertEntry(_entry('e-don', 'm-don', 'w-morning'));
  await repo.upsertEntry(_entry('e-mem', 'm-mem', 'w-bed'));
  // Ibuprofen is intentionally window-less → "No time window yet" prompt.
  return repo;
}

Widget _host(MedicationRepository repo) {
  final GoRouter router = GoRouter(
    initialLocation: '/medications',
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        builder: (BuildContext context, GoRouterState state) =>
            const MedicationListScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      medicationRepositoryBackendProvider.overrideWithValue(repo),
      medicationListClockProvider.overrideWithValue(_fixedNow),
      storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
    ],
    child: SizedBox(
      width: 420,
      height: 1000,
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
  group('MedicationListScreen golden', () {
    goldenTest(
      'populated — three meds, windows + adherence',
      fileName: 'medication_list_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated',
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
      'empty — no medications yet',
      fileName: 'medication_list_screen_empty',
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

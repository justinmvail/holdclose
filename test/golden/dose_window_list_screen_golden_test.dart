import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medication/dose_window_list_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

DateTime _fixedNow() => DateTime(2026, 6, 4, 9, 0);

DoseWindow _window(
  String id,
  String label, {
  TimeOfDay? anchor = const TimeOfDay(hour: 8, minute: 0),
  int sortOrder = 0,
}) =>
    DoseWindow(
      id: id,
      patientId: _patientId,
      label: label,
      anchorTime: anchor,
      sortOrder: sortOrder,
    );

MedicationRepository _repo() =>
    MedicationRepository(CareblazersDatabase(NativeDatabase.memory()),
        clock: _fixedNow);

Future<MedicationRepository> _populatedRepo() async {
  final MedicationRepository repo = _repo();
  await repo.upsertWindow(_window('w-morning', 'Morning'));
  await repo.upsertWindow(_window('w-noon', 'Noon',
      anchor: const TimeOfDay(hour: 12, minute: 0), sortOrder: 1));
  await repo.upsertWindow(_window('w-bed', 'Bedtime',
      anchor: const TimeOfDay(hour: 21, minute: 0), sortOrder: 2));
  // An "as needed" window (no anchor time) renders the "As needed" subtitle.
  await repo.upsertWindow(_window('w-prn', 'As needed',
      anchor: null, sortOrder: 3));
  return repo;
}

Widget _host(MedicationRepository repo) {
  final GoRouter router = GoRouter(
    initialLocation: '/medications/windows',
    routes: <RouteBase>[
      GoRoute(
        path: '/medications/windows',
        builder: (BuildContext context, GoRouterState state) =>
            const DoseWindowListScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      medicationRepositoryBackendProvider.overrideWithValue(repo),
      storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
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

void main() {
  group('DoseWindowListScreen golden', () {
    goldenTest(
      'populated — four time windows incl. As needed',
      fileName: 'dose_window_list_screen_populated',
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
      'empty — no time windows yet',
      fileName: 'dose_window_list_screen_empty',
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

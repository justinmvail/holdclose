import 'package:alchemist/alchemist.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/health_log_entry.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/screens/medical/health_log_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 6, 1, 12);

HealthLogRepository _emptyRepo() =>
    HealthLogRepository(HoldcloseDatabase(NativeDatabase.memory()));

Future<HealthLogRepository> _populatedRepo() async {
  final HealthLogRepository repo =
      HealthLogRepository(HoldcloseDatabase(NativeDatabase.memory()));
  HealthLogEntry e({
    required String id,
    required DateTime at,
    required HealthLogKind kind,
    int? severity,
    int? systolic,
    int? diastolic,
    int? heartRate,
    double? temperatureF,
    double? weightLbs,
    String? notes,
  }) =>
      HealthLogEntry(
        id: id,
        patientId: 'demo-patient-mary',
        recordedAt: at,
        kind: kind,
        severity: severity,
        systolic: systolic,
        diastolic: diastolic,
        heartRate: heartRate,
        temperatureF: temperatureF,
        weightLbs: weightLbs,
        notes: notes,
      );

  await repo.upsert(e(
    id: 'v1',
    at: DateTime(2026, 6, 1, 10),
    kind: HealthLogKind.vitals,
    systolic: 130,
    diastolic: 82,
    heartRate: 76,
    temperatureF: 98.6,
    weightLbs: 152,
  ));
  await repo.upsert(e(
    id: 's1',
    at: DateTime(2026, 5, 31, 15),
    kind: HealthLogKind.symptom,
    severity: 3,
    notes: 'Headache, holding her right temple',
  ));
  await repo.upsert(e(
    id: 'n1',
    at: DateTime(2026, 5, 31, 9),
    kind: HealthLogKind.note,
    notes: 'Slept well and ate a full breakfast. Calmer afternoon.',
  ));
  return repo;
}

Widget _host(HealthLogRepository repo) {
  final GoRouter router = GoRouter(
    initialLocation: '/medical/health-log',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/health-log',
        builder: (BuildContext context, GoRouterState state) =>
            const HealthLogScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      healthLogRepositoryProvider.overrideWithValue(repo),
      healthLogClockProvider.overrideWithValue(_fixedNow),
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
  group('HealthLogScreen golden', () {
    goldenTest(
      'empty health log',
      fileName: 'health_log_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 14.17)',
            child: _host(_emptyRepo()),
          ),
        ],
      ),
    );

    goldenTest(
      'populated health log — grouped by day',
      fileName: 'health_log_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 14.17)',
            child: FutureBuilder<HealthLogRepository>(
              future: _populatedRepo(),
              builder: (BuildContext context,
                  AsyncSnapshot<HealthLogRepository> snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                return _host(snap.data!);
              },
            ),
          ),
        ],
      ),
    );
  });
}

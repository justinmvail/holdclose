import 'package:alchemist/alchemist.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/health_log_entry.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/medical/health_log_entry_form.dart';
import 'package:holdclose/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 6, 1, 9, 30);

Future<HealthLogRepository> _repoWithEdit() async {
  final HealthLogRepository repo =
      HealthLogRepository(HoldcloseDatabase(NativeDatabase.memory()));
  await repo.upsert(HealthLogEntry(
    id: 'hl-edit',
    patientId: 'demo-patient-mary',
    recordedAt: DateTime(2026, 6, 1, 8),
    kind: HealthLogKind.vitals,
    systolic: 128,
    diastolic: 80,
    heartRate: 72,
    temperatureF: 98.4,
    weightLbs: 152.5,
    notes: 'Resting, before breakfast.',
  ));
  return repo;
}

Widget _host(HealthLogRepository repo, {String? editEntryId}) {
  final String initialLocation = editEntryId == null
      ? '/medical/health-log/new'
      : '/medical/health-log/$editEntryId/edit';
  final GoRouter router = GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/health-log',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            builder: (BuildContext context, GoRouterState state) =>
                const HealthLogEntryForm(),
          ),
          GoRoute(
            path: ':id/edit',
            builder: (BuildContext context, GoRouterState state) =>
                HealthLogEntryForm(entryId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      healthLogRepositoryProvider.overrideWithValue(repo),
      storageProvider.overrideWithValue(InMemoryStorageProvider()),
      healthLogClockProvider.overrideWithValue(_fixedNow),
      healthLogFormIdFactoryProvider.overrideWithValue(() => 'golden-id'),
    ],
    child: SizedBox(
      width: 420,
      height: 1500,
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
  group('HealthLogEntryForm golden', () {
    goldenTest(
      'new entry form — defaults to vitals',
      fileName: 'health_log_entry_form_new',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'new form (Phase 14.17)',
            child: _host(
              HealthLogRepository(HoldcloseDatabase(NativeDatabase.memory())),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'edit entry form — hydrated vitals',
      fileName: 'health_log_entry_form_edit',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'edit form (Phase 14.17)',
            child: FutureBuilder<HealthLogRepository>(
              future: _repoWithEdit(),
              builder: (BuildContext context,
                  AsyncSnapshot<HealthLogRepository> snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                return _host(snap.data!, editEntryId: 'hl-edit');
              },
            ),
          ),
        ],
      ),
    );
  });
}

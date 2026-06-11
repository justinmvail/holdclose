import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_plan_routine.dart';
import 'package:careblazers/models/care_task.dart';
import 'package:careblazers/models/medication.dart' show FrequencyKind;
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/screens/medical/care_plan_routines_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

CarePlanRoutine _routine(
  String id,
  String title, {
  TimeOfDay scheduledTime = const TimeOfDay(hour: 8, minute: 0),
  FrequencyKind frequencyKind = FrequencyKind.daily,
}) =>
    CarePlanRoutine(
      id: id,
      patientId: _patientId,
      title: title,
      body: '',
      scheduledTime: scheduledTime,
      frequencyKind: frequencyKind,
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 6, 1),
    );

/// One fresh in-memory db per repo pair so the two repos share the same
/// backing store (the "· N tasks" suffix joins routines to child tasks).
({CarePlanRepository plan, CareTasksRepository tasks}) _repos() {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  return (plan: CarePlanRepository(db), tasks: CareTasksRepository(db));
}

Future<({CarePlanRepository plan, CareTasksRepository tasks})>
    _populatedRepos() async {
  final ({CarePlanRepository plan, CareTasksRepository tasks}) r = _repos();
  await r.plan.upsert(_routine(
    'r-1',
    'Morning hygiene',
    scheduledTime: const TimeOfDay(hour: 7, minute: 30),
  ));
  await r.plan.upsert(_routine(
    'r-2',
    'Evening wind-down',
    scheduledTime: const TimeOfDay(hour: 20, minute: 0),
    frequencyKind: FrequencyKind.weekly,
  ));
  // Two child tasks under the morning routine → "· 2 tasks" suffix.
  await r.tasks.upsertTask(const CareTask(
    id: 'child-1',
    title: 'Brush teeth',
    patientId: _patientId,
    routineId: 'r-1',
  ));
  await r.tasks.upsertTask(const CareTask(
    id: 'child-2',
    title: 'Wash face',
    patientId: _patientId,
    routineId: 'r-1',
  ));
  return r;
}

Widget _host(({CarePlanRepository plan, CareTasksRepository tasks}) repos) {
  final GoRouter router = GoRouter(
    initialLocation: '/medical/routines',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/routines',
        builder: (BuildContext context, GoRouterState state) =>
            const CarePlanRoutinesScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      carePlanRepositoryProvider.overrideWithValue(repos.plan),
      careTasksRepositoryProvider.overrideWithValue(repos.tasks),
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
  group('CarePlanRoutinesScreen golden', () {
    goldenTest(
      'populated routines list — daily + weekly, with task counts',
      fileName: 'care_plan_routines_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated',
            child: FutureBuilder<
                ({CarePlanRepository plan, CareTasksRepository tasks})>(
              future: _populatedRepos(),
              builder: (BuildContext context,
                  AsyncSnapshot<
                          ({
                            CarePlanRepository plan,
                            CareTasksRepository tasks
                          })>
                      snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                return _host(snap.data!);
              },
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'empty routines list',
      fileName: 'care_plan_routines_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty',
            child: _host(_repos()),
          ),
        ],
      ),
    );
  });
}

import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medical/care_plan_routine_form.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI golden of the add-routine form at `/medical/routines/new`
/// (BUILD_SPEC.md §5.13). The empty form is the richest deterministic
/// view — title + notes fields, the inline task editor, the 8:00 AM time
/// row, and the frequency dropdown (Daily, so no weekday picker).
///
/// Repos run on a shared in-memory db; an empty [storageProvider] keeps
/// the active-patient lookup off the on-device sqlite file (it only fires
/// on submit anyway).
({CarePlanRepository plan, CareTasksRepository tasks}) _repos() {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  return (plan: CarePlanRepository(db), tasks: CareTasksRepository(db));
}

Widget _host() {
  final ({CarePlanRepository plan, CareTasksRepository tasks}) repos = _repos();
  final GoRouter router = GoRouter(
    initialLocation: '/medical/routines/new',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/routines',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            builder: (BuildContext context, GoRouterState state) =>
                const CarePlanRoutineForm(),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      carePlanRepositoryProvider.overrideWithValue(repos.plan),
      careTasksRepositoryProvider.overrideWithValue(repos.tasks),
      storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
    ],
    child: SizedBox(
      width: 420,
      height: 1100,
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
  group('CarePlanRoutineForm golden', () {
    goldenTest(
      'empty add-routine form',
      fileName: 'care_plan_routine_form_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'add routine (empty)',
            child: _host(),
          ),
        ],
      ),
    );
  });
}

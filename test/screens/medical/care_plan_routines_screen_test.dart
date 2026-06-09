import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_plan_routine.dart';
import 'package:careblazers/models/care_task.dart';
import 'package:careblazers/models/medication.dart' show FrequencyKind;
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/screens/medical/care_plan_routines_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Coverage for the Care-Plan Routines list screen (`/medical/routines`) —
/// the management surface that previously had zero tests. Drives the real
/// screen against an in-memory repo: empty state, a populated list that
/// renders each routine, tapping a row → the edit route, and the add
/// affordance → the new route.
///
/// Mirrors the form tests' harness: in-memory CareblazersDatabase, a
/// GoRouter with the routines list at the parent and `new` / `:id` child
/// stubs that record the location they were pushed to, the repo provider
/// overridden, and pumpAndSettle.

CarePlanRoutine _routine(
  String id,
  String title, {
  TimeOfDay scheduledTime = const TimeOfDay(hour: 8, minute: 0),
  FrequencyKind frequencyKind = FrequencyKind.daily,
}) =>
    CarePlanRoutine(
      id: id,
      patientId: 'demo-patient-mary',
      title: title,
      body: '',
      scheduledTime: scheduledTime,
      frequencyKind: frequencyKind,
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 6, 1),
    );

Future<List<String>> _pumpScreen(
  WidgetTester tester, {
  required CarePlanRepository repo,
  required CareTasksRepository tasksRepo,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  // Records every child route the list pushed to, so a tap assertion can
  // read the navigated location without depending on screen internals.
  final List<String> pushed = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();

  final GoRouter router = GoRouter(
    initialLocation: '/medical/routines',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/routines',
        parentNavigatorKey: rootKey,
        builder: (BuildContext c, GoRouterState s) =>
            const CarePlanRoutinesScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) {
              pushed.add('/medical/routines/new');
              return const Scaffold(body: Center(child: Text('new-stub')));
            },
          ),
          GoRoute(
            path: ':id',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) {
              pushed.add('/medical/routines/${s.pathParameters['id']}');
              return const Scaffold(body: Center(child: Text('edit-stub')));
            },
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        carePlanRepositoryProvider.overrideWithValue(repo),
        // The "· N tasks" suffix reads routineTaskCounts → careTasks →
        // careTasksRepository; override it onto the same in-memory db so the
        // screen never opens the on-device sqlite file.
        careTasksRepositoryProvider.overrideWithValue(tasksRepo),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return pushed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CareblazersDatabase db;
  late CarePlanRepository repo;
  late CareTasksRepository tasksRepo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = CarePlanRepository(db);
    tasksRepo = CareTasksRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('CarePlanRoutinesScreen — empty', () {
    testWidgets('renders the empty state when there are no routines',
        (WidgetTester tester) async {
      await _pumpScreen(tester, repo: repo, tasksRepo: tasksRepo);

      expect(find.byKey(CarePlanRoutinesScreen.emptyStateKey), findsOneWidget);
      expect(find.text('No routines yet.'), findsOneWidget);
      // The list isn't built when empty.
      expect(find.byKey(CarePlanRoutinesScreen.listKey), findsNothing);
      // The add affordance is always present.
      expect(find.byKey(CarePlanRoutinesScreen.addFabKey), findsOneWidget);
    });
  });

  group('CarePlanRoutinesScreen — populated', () {
    testWidgets('renders a row per routine with its title',
        (WidgetTester tester) async {
      await repo.upsert(_routine(
        'r-1',
        'Morning hygiene',
        scheduledTime: const TimeOfDay(hour: 7, minute: 30),
      ));
      await repo.upsert(_routine(
        'r-2',
        'Evening wind-down',
        scheduledTime: const TimeOfDay(hour: 20, minute: 0),
        frequencyKind: FrequencyKind.weekly,
      ));

      await _pumpScreen(tester, repo: repo, tasksRepo: tasksRepo);

      expect(find.byKey(CarePlanRoutinesScreen.listKey), findsOneWidget);
      expect(find.byKey(CarePlanRoutinesScreen.emptyStateKey), findsNothing);
      expect(find.text('Morning hygiene'), findsOneWidget);
      expect(find.text('Evening wind-down'), findsOneWidget);
      // Each routine has a keyed row.
      expect(find.byKey(CarePlanRoutinesScreen.rowKey('r-1')), findsOneWidget);
      expect(find.byKey(CarePlanRoutinesScreen.rowKey('r-2')), findsOneWidget);
    });

    testWidgets('shows the "· N tasks" suffix from the routine\'s child tasks',
        (WidgetTester tester) async {
      await repo.upsert(_routine('r-1', 'Morning hygiene'));
      // Two child tasks bundled under the routine.
      await tasksRepo.upsertTask(const CareTask(
        id: 'child-1',
        title: 'Brush teeth',
        patientId: 'demo-patient-mary',
        routineId: 'r-1',
      ));
      await tasksRepo.upsertTask(const CareTask(
        id: 'child-2',
        title: 'Wash face',
        patientId: 'demo-patient-mary',
        routineId: 'r-1',
      ));

      await _pumpScreen(tester, repo: repo, tasksRepo: tasksRepo);

      expect(find.textContaining('· 2 tasks'), findsOneWidget);
    });
  });

  group('CarePlanRoutinesScreen — navigation', () {
    testWidgets('tapping a row pushes the edit route for that routine',
        (WidgetTester tester) async {
      await repo.upsert(_routine('r-1', 'Morning hygiene'));

      final List<String> pushed = await _pumpScreen(tester, repo: repo, tasksRepo: tasksRepo);

      await tester.tap(find.byKey(CarePlanRoutinesScreen.rowKey('r-1')));
      await tester.pumpAndSettle();

      expect(pushed, contains('/medical/routines/r-1'));
      expect(find.text('edit-stub'), findsOneWidget);
    });

    testWidgets('tapping the add affordance pushes the new route',
        (WidgetTester tester) async {
      final List<String> pushed = await _pumpScreen(tester, repo: repo, tasksRepo: tasksRepo);

      await tester.tap(find.byKey(CarePlanRoutinesScreen.addFabKey));
      await tester.pumpAndSettle();

      expect(pushed, contains('/medical/routines/new'));
      expect(find.text('new-stub'), findsOneWidget);
    });
  });
}

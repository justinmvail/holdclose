import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_plan_routine.dart';
import 'package:careblazers/models/care_task.dart';
import 'package:careblazers/models/medication.dart' show FrequencyKind;
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medical/care_plan_routine_form.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// End-to-end form coverage for the Care-Plan Routine add/edit/delete
/// screen (`/medical/routines/new`, `/medical/routines/:id`) — the
/// routine editing surface that previously had zero tests. Drives the
/// real form against an in-memory repo: create (with weekly days-of-week),
/// validation, the weekly-only conditional, edit + persist (same id, no
/// duplicate), and delete. Asserts persistence through the repo.
///
/// Mirrors `medication_form_screen_test.dart` /
/// `health_log_entry_form_test.dart`: in-memory CareblazersDatabase, a
/// GoRouter with a parent list-stub plus the child form routes, the
/// repo provider overridden, pumpAndSettle, and assertions on repo state
/// plus the "popped back to the list" stub.

CarePlanRoutine _routine(
  String id,
  String title, {
  TimeOfDay scheduledTime = const TimeOfDay(hour: 8, minute: 0),
  FrequencyKind frequencyKind = FrequencyKind.daily,
  Set<int> daysOfWeek = const <int>{},
  String body = '',
}) =>
    CarePlanRoutine(
      id: id,
      patientId: 'demo-patient-mary',
      title: title,
      body: body,
      scheduledTime: scheduledTime,
      frequencyKind: frequencyKind,
      daysOfWeek: daysOfWeek,
      startsOn: DateTime(2026, 6, 1),
    );

Future<CarePlanRepository> _pumpForm(
  WidgetTester tester, {
  required CarePlanRepository repo,
  required CareTasksRepository tasksRepo,
  String? editId,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final String location = editId == null
      ? '/medical/routines/new'
      : '/medical/routines/$editId';

  final GoRouter router = GoRouter(
    initialLocation: location,
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/routines',
        parentNavigatorKey: rootKey,
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('list-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) =>
                const CarePlanRoutineForm(),
          ),
          GoRoute(
            path: ':id',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) =>
                CarePlanRoutineForm(routineId: s.pathParameters['id']),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        carePlanRepositoryProvider.overrideWithValue(repo),
        // Child tasks (unified task/routine model) reconcile through the
        // tasks repo on the same in-memory db.
        careTasksRepositoryProvider.overrideWithValue(tasksRepo),
        // The add path now resolves the active loved one via
        // activePatientIdProvider → storageProvider; an empty in-memory
        // store keeps the test off the on-device sqlite file and falls back
        // to 'demo-patient-mary', so a new routine's patientId is unchanged.
        // The edit path keeps the existing routine's own patientId.
        storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

/// Switch the frequency dropdown to a given value by opening it and
/// tapping the menu entry. `DropdownButtonFormField` renders two copies of
/// each label (the closed selection + the open menu item), so we tap the
/// `.last` (the overlay menu item) once the menu is open.
Future<void> _selectFrequency(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(CarePlanRoutineForm.frequencyDropdownKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
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

  group('CarePlanRoutineForm — create', () {
    testWidgets('fills a daily routine, saves, persists, and pops to the list',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, tasksRepo: tasksRepo);

      await tester.enterText(
          find.byKey(CarePlanRoutineForm.titleFieldKey), 'Morning hygiene');
      await tester.enterText(
          find.byKey(CarePlanRoutineForm.bodyFieldKey), 'Wash up, brush teeth');
      await tester.tap(find.byKey(CarePlanRoutineForm.submitButtonKey));
      await tester.pumpAndSettle();

      final List<CarePlanRoutine> routines = await repo.listAll();
      expect(routines, hasLength(1));
      final CarePlanRoutine saved = routines.single;
      // Id is minted by the form (DateTime.now + Random); just assert it
      // exists and carries the routine prefix.
      expect(saved.id, startsWith('routine-'));
      expect(saved.title, 'Morning hygiene');
      expect(saved.body, 'Wash up, brush teeth');
      expect(saved.frequencyKind, FrequencyKind.daily);
      // Default time anchor when the picker is untouched.
      expect(saved.scheduledTime, const TimeOfDay(hour: 8, minute: 0));
      // Daily carries no days-of-week subset.
      expect(saved.daysOfWeek, isEmpty);
      // Popped back to the routines list.
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('adding tasks reconciles real child CareTasks for the routine',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, tasksRepo: tasksRepo);

      await tester.enterText(
          find.byKey(CarePlanRoutineForm.titleFieldKey), 'Morning hygiene');

      // Add two child tasks via the inline editor.
      await tester.enterText(
          find.byKey(CarePlanRoutineForm.subtaskFieldKey), 'Brush teeth');
      await tester.tap(find.byKey(CarePlanRoutineForm.subtaskAddKey));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(CarePlanRoutineForm.subtaskFieldKey), 'Wash face');
      await tester.tap(find.byKey(CarePlanRoutineForm.subtaskAddKey));
      await tester.pumpAndSettle();

      // Remove the first one, leaving just "Wash face".
      await tester.tap(find.byKey(CarePlanRoutineForm.subtaskRemoveKey(0)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(CarePlanRoutineForm.submitButtonKey));
      await tester.pumpAndSettle();

      // Under the unified model the string checklist is gone — the routine
      // bundles real child CareTasks linked by routineId.
      final CarePlanRoutine saved = (await repo.listAll()).single;
      expect(saved.subtasks, isEmpty);

      final List<CareTask> children = (await tasksRepo.listTasks())
          .where((CareTask t) => t.routineId == saved.id)
          .toList();
      expect(children.map((CareTask t) => t.title), <String>['Wash face']);
      // Child tasks are bundled, not standalone, and inherit the routine's
      // patient.
      expect(children.single.isStandalone, isFalse);
      expect(children.single.patientId, saved.patientId);
    });

    testWidgets('edit hydrates existing child tasks and shows them',
        (WidgetTester tester) async {
      await repo.upsert(_routine('r-steps', 'Bedtime'));
      // Seed two child tasks linked to the routine.
      await tasksRepo.upsertTask(const CareTask(
        id: 'child-1',
        title: 'Dim lights',
        patientId: 'demo-patient-mary',
        routineId: 'r-steps',
      ));
      await tasksRepo.upsertTask(const CareTask(
        id: 'child-2',
        title: 'Lay out clothes',
        patientId: 'demo-patient-mary',
        routineId: 'r-steps',
      ));
      await _pumpForm(tester,
          repo: repo, tasksRepo: tasksRepo, editId: 'r-steps');

      // Both persisted child tasks render in the editor.
      expect(find.text('Dim lights'), findsOneWidget);
      expect(find.text('Lay out clothes'), findsOneWidget);
    });

    testWidgets(
        'a weekly routine persists the picked days-of-week subset',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, tasksRepo: tasksRepo);

      await tester.enterText(
          find.byKey(CarePlanRoutineForm.titleFieldKey), 'Bath day');
      await _selectFrequency(tester, 'Weekly (pick days)');

      // Weekly defaults to all seven days selected; deselect everything
      // except Wed + Sat so we can assert a meaningful subset survives.
      const List<String> all = <String>[
        'Mon', 'Tue', 'Thu', 'Fri', 'Sun' // leave Wed + Sat on
      ];
      for (final String day in all) {
        await tester.tap(find.widgetWithText(FilterChip, day));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byKey(CarePlanRoutineForm.submitButtonKey));
      await tester.pumpAndSettle();

      final CarePlanRoutine saved = (await repo.listAll()).single;
      expect(saved.frequencyKind, FrequencyKind.weekly);
      // Wed = 3, Sat = 6 (Mon = 1 … Sun = 7).
      expect(saved.daysOfWeek, <int>{3, 6});
      expect(find.text('list-stub'), findsOneWidget);
    });
  });

  group('CarePlanRoutineForm — validation', () {
    testWidgets('an empty title is rejected and nothing persists',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, tasksRepo: tasksRepo);

      // Leave the title blank; fill only the optional notes.
      await tester.enterText(
          find.byKey(CarePlanRoutineForm.bodyFieldKey), 'some notes');
      await tester.tap(find.byKey(CarePlanRoutineForm.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Title is required.'), findsOneWidget);
      expect(await repo.listAll(), isEmpty);
      // Still on the form, never popped to the list.
      expect(find.text('list-stub'), findsNothing);
    });
  });

  group('CarePlanRoutineForm — days-of-week conditional', () {
    testWidgets('day chips are hidden for daily and shown only for weekly',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, tasksRepo: tasksRepo);

      // Daily (the default): no weekday chips.
      expect(find.widgetWithText(FilterChip, 'Mon'), findsNothing);
      expect(find.widgetWithText(FilterChip, 'Sun'), findsNothing);

      // Weekly: the seven-day picker appears.
      await _selectFrequency(tester, 'Weekly (pick days)');
      for (final String day in <String>[
        'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
      ]) {
        expect(find.widgetWithText(FilterChip, day), findsOneWidget);
      }

      // As-needed: the picker is hidden again.
      await _selectFrequency(tester, 'As needed (no schedule)');
      expect(find.widgetWithText(FilterChip, 'Mon'), findsNothing);
    });
  });

  group('CarePlanRoutineForm — edit', () {
    testWidgets(
        'hydrates the existing routine, edits the title, updates in place',
        (WidgetTester tester) async {
      await repo.upsert(_routine(
        'routine-9',
        'Evening wind-down',
        scheduledTime: const TimeOfDay(hour: 20, minute: 0),
        body: 'Dim lights, calm music',
      ));

      await _pumpForm(tester, repo: repo, tasksRepo: tasksRepo, editId: 'routine-9');

      // Hydrated values land in the fields.
      expect(find.text('Evening wind-down'), findsOneWidget);
      expect(find.text('Dim lights, calm music'), findsOneWidget);

      await tester.enterText(
          find.byKey(CarePlanRoutineForm.titleFieldKey), 'Evening routine');
      await tester.tap(find.byKey(CarePlanRoutineForm.submitButtonKey));
      await tester.pumpAndSettle();

      final List<CarePlanRoutine> routines = await repo.listAll();
      expect(routines, hasLength(1)); // same row, no duplicate
      final CarePlanRoutine updated = routines.single;
      expect(updated.id, 'routine-9'); // id preserved
      expect(updated.title, 'Evening routine');
      expect(updated.body, 'Dim lights, calm music'); // untouched
      expect(find.text('list-stub'), findsOneWidget);
    });
  });

  group('CarePlanRoutineForm — delete', () {
    testWidgets('delete is edit-only, confirms, then removes the routine',
        (WidgetTester tester) async {
      // Add path: no delete affordance.
      await _pumpForm(tester, repo: repo, tasksRepo: tasksRepo);
      expect(find.byKey(CarePlanRoutineForm.deleteButtonKey), findsNothing);

      // Edit path: the delete action confirms then drops the row.
      await repo.upsert(_routine('routine-7', 'Hydration check'));
      await _pumpForm(tester, repo: repo, tasksRepo: tasksRepo, editId: 'routine-7');
      expect(find.byKey(CarePlanRoutineForm.deleteButtonKey), findsOneWidget);

      await tester.tap(find.byKey(CarePlanRoutineForm.deleteButtonKey));
      await tester.pumpAndSettle();
      // Confirm dialog.
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(await repo.listAll(), isEmpty);
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('cancelling the delete dialog keeps the routine',
        (WidgetTester tester) async {
      await repo.upsert(_routine('routine-7', 'Hydration check'));
      await _pumpForm(tester, repo: repo, tasksRepo: tasksRepo, editId: 'routine-7');

      await tester.tap(find.byKey(CarePlanRoutineForm.deleteButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(await repo.listAll(), hasLength(1));
    });
  });
}

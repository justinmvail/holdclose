import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_task.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/screens/team/tasks_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';
const String _me = 'demo-caregiver-me';
final DateTime _clock = DateTime.utc(2026, 6, 1, 12);

CareTask _task({
  required String id,
  String title = 'Pick up prescription',
  String? assigneeCaregiverId,
  DateTime? claimedAt,
  DateTime? completedAt,
}) =>
    CareTask(
      id: id,
      title: title,
      assigneeCaregiverId: assigneeCaregiverId,
      claimedAt: claimedAt,
      completedAt: completedAt,
      patientId: _patientId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CareblazersDatabase db;
  late CareTasksRepository tasksRepo;
  late CareCircleRepository circleRepo;
  int ids = 0;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    tasksRepo = CareTasksRepository(db);
    circleRepo = CareCircleRepository(db);
    ids = 0;
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(460, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          careTasksRepositoryProvider.overrideWithValue(tasksRepo),
          careCircleRepositoryProvider.overrideWithValue(circleRepo),
          careTasksClockProvider.overrideWithValue(() => _clock),
          currentCaregiverIdProvider.overrideWithValue(_me),
          taskIdFactoryProvider.overrideWithValue(() => 'new-${ids++}'),
        ],
        child: const MaterialApp(home: TasksScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapSegment(WidgetTester tester, CareTaskStatus status) async {
    await tester.tap(find.byKey(TasksScreen.segmentKey(status)));
    await tester.pumpAndSettle();
  }

  group('TasksScreen — segmented filtering', () {
    testWidgets('each segment shows only its own tasks', (tester) async {
      await tasksRepo.upsertTask(_task(id: 'open1', title: 'Open task'));
      await tasksRepo.upsertTask(_task(
        id: 'claimed1',
        title: 'Claimed task',
        assigneeCaregiverId: _me,
        claimedAt: _clock,
      ));
      await tasksRepo.upsertTask(_task(
        id: 'done1',
        title: 'Done task',
        assigneeCaregiverId: _me,
        claimedAt: _clock,
        completedAt: _clock,
      ));

      await pump(tester);

      // Defaults to Open.
      expect(find.byKey(TasksScreen.cardKey('open1')), findsOneWidget);
      expect(find.byKey(TasksScreen.cardKey('claimed1')), findsNothing);
      expect(find.byKey(TasksScreen.cardKey('done1')), findsNothing);

      await tapSegment(tester, CareTaskStatus.claimed);
      expect(find.byKey(TasksScreen.cardKey('claimed1')), findsOneWidget);
      expect(find.byKey(TasksScreen.cardKey('open1')), findsNothing);

      await tapSegment(tester, CareTaskStatus.done);
      expect(find.byKey(TasksScreen.cardKey('done1')), findsOneWidget);
      expect(find.byKey(TasksScreen.cardKey('claimed1')), findsNothing);
    });

    testWidgets('empty segment shows the empty-state copy', (tester) async {
      await pump(tester);
      expect(find.byKey(TasksScreen.emptyStateKey), findsOneWidget);
    });
  });

  group('TasksScreen — action buttons swap by state', () {
    testWidgets('open task shows only Claim', (tester) async {
      await tasksRepo.upsertTask(_task(id: 't1'));
      await pump(tester);

      expect(find.byKey(TasksScreen.claimButtonKey('t1')), findsOneWidget);
      expect(find.byKey(TasksScreen.completeButtonKey('t1')), findsNothing);
      expect(find.byKey(TasksScreen.unclaimButtonKey('t1')), findsNothing);
    });

    testWidgets('claiming moves the task to Claimed with Complete + Unclaim',
        (tester) async {
      await tasksRepo.upsertTask(_task(id: 't1'));
      await pump(tester);

      await tester.tap(find.byKey(TasksScreen.claimButtonKey('t1')));
      await tester.pumpAndSettle();

      // Gone from Open now.
      expect(find.byKey(TasksScreen.cardKey('t1')), findsNothing);

      await tapSegment(tester, CareTaskStatus.claimed);
      expect(find.byKey(TasksScreen.completeButtonKey('t1')), findsOneWidget);
      expect(find.byKey(TasksScreen.unclaimButtonKey('t1')), findsOneWidget);
      expect(find.byKey(TasksScreen.claimButtonKey('t1')), findsNothing);
      // The assignee chip now reads "You".
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('completing a claimed task moves it to Done with no actions',
        (tester) async {
      await tasksRepo.upsertTask(_task(
        id: 't1',
        assigneeCaregiverId: _me,
        claimedAt: _clock,
      ));
      await pump(tester);
      await tapSegment(tester, CareTaskStatus.claimed);

      await tester.tap(find.byKey(TasksScreen.completeButtonKey('t1')));
      await tester.pumpAndSettle();

      await tapSegment(tester, CareTaskStatus.done);
      expect(find.byKey(TasksScreen.cardKey('t1')), findsOneWidget);
      expect(find.byKey(TasksScreen.completeButtonKey('t1')), findsNothing);
      expect(find.byKey(TasksScreen.unclaimButtonKey('t1')), findsNothing);
      expect(find.byKey(TasksScreen.claimButtonKey('t1')), findsNothing);
    });

    testWidgets('unclaiming returns the task to the open pool', (tester) async {
      await tasksRepo.upsertTask(_task(
        id: 't1',
        assigneeCaregiverId: _me,
        claimedAt: _clock,
      ));
      await pump(tester);
      await tapSegment(tester, CareTaskStatus.claimed);

      await tester.tap(find.byKey(TasksScreen.unclaimButtonKey('t1')));
      await tester.pumpAndSettle();

      expect(find.byKey(TasksScreen.cardKey('t1')), findsNothing);
      await tapSegment(tester, CareTaskStatus.open);
      expect(find.byKey(TasksScreen.claimButtonKey('t1')), findsOneWidget);
    });

    testWidgets('a task claimed by someone else shows no actions for me',
        (tester) async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'other',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await tasksRepo.upsertTask(_task(
        id: 't1',
        assigneeCaregiverId: 'other',
        claimedAt: _clock,
      ));
      await pump(tester);
      await tapSegment(tester, CareTaskStatus.claimed);

      expect(find.byKey(TasksScreen.cardKey('t1')), findsOneWidget);
      expect(find.byKey(TasksScreen.completeButtonKey('t1')), findsNothing);
      expect(find.byKey(TasksScreen.unclaimButtonKey('t1')), findsNothing);
      expect(find.byKey(TasksScreen.claimButtonKey('t1')), findsNothing);
      // The resolved assignee name renders.
      expect(find.text('Maria Lopez'), findsOneWidget);
    });
  });

  group('TasksScreen — create sheet', () {
    testWidgets('FAB opens the create sheet', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(TasksScreen.fabKey));
      await tester.pumpAndSettle();
      expect(find.byKey(TasksScreen.createSheetKey), findsOneWidget);
    });

    testWidgets('saving with an empty title shows an error and adds nothing',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(TasksScreen.fabKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(TasksScreen.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(TasksScreen.titleErrorKey), findsOneWidget);
      expect(await tasksRepo.listTasks(), isEmpty);
    });

    testWidgets('a titled task is created and lands in Open', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(TasksScreen.fabKey));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(TasksScreen.titleFieldKey), 'Call the pharmacy');
      await tester.tap(find.byKey(TasksScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // Sheet closed, task on the Open board.
      expect(find.byKey(TasksScreen.createSheetKey), findsNothing);
      expect(find.text('Call the pharmacy'), findsOneWidget);

      final List<CareTask> tasks = await tasksRepo.listTasks();
      expect(tasks.single.title, 'Call the pharmacy');
      expect(tasks.single.status, CareTaskStatus.open);
    });
  });
}

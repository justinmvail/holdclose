import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/care_task.dart';
import 'package:holdclose/models/caregiver.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/team/tasks_screen.dart';
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

  late HoldcloseDatabase db;
  late CareTasksRepository tasksRepo;
  late CareCircleRepository circleRepo;
  int ids = 0;

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
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
          // Creating a task now resolves the active loved one via
          // activePatientIdProvider → storageProvider; an empty in-memory
          // store keeps the test off the on-device sqlite file and falls
          // back to 'demo-patient-mary' (== _patientId), so the stamped
          // patientId is unchanged.
          storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
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

    testWidgets(
        'a fully-filled task persists title, details, due, and assignee',
        (tester) async {
      // An assignee chip only renders for a roster caregiver.
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'maria',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await pump(tester);

      // The Material time picker's action row needs more vertical room than
      // the default 460x900 to render its OK button on-screen; grow the
      // surface so the due picker confirms cleanly. (pump()'s tearDown
      // already restores the size to null.)
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(TasksScreen.fabKey));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(TasksScreen.titleFieldKey), 'Refill blood pressure meds');
      await tester.enterText(
          find.byKey(TasksScreen.bodyFieldKey), 'Two prescriptions at CVS.');

      // Pick the seeded caregiver. The chip sits low in the scrollable sheet,
      // so bring it into view before tapping.
      final Finder assignee =
          find.byKey(TasksScreen.assigneeOptionKey('maria'));
      await tester.ensureVisible(assignee);
      await tester.pumpAndSettle();
      await tester.tap(assignee);
      await tester.pumpAndSettle();

      // Set a due time last (it's a modal that takes over the screen): open
      // the date picker, accept the default date, then the default time —
      // same flow the shifts schedule sheet uses.
      await tester.tap(find.byKey(TasksScreen.dueButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final Finder save = find.byKey(TasksScreen.saveButtonKey);
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      // Sheet closed; the task renders on the Open board with its details.
      expect(find.byKey(TasksScreen.createSheetKey), findsNothing);
      expect(find.text('Refill blood pressure meds'), findsOneWidget);
      expect(find.text('Two prescriptions at CVS.'), findsOneWidget);

      // The whole payload persisted to the in-memory repository.
      final List<CareTask> tasks = await tasksRepo.listTasks();
      final CareTask saved = tasks.single;
      expect(saved.title, 'Refill blood pressure meds');
      expect(saved.body, 'Two prescriptions at CVS.');
      expect(saved.assigneeCaregiverId, 'maria');
      // The default date+time picker yields the clock's day, 9:00 — the form
      // seeds the time picker from "now" (the pinned clock at 12:00) but the
      // accepted default keeps it the pinned date; assert the date persisted.
      expect(saved.dueAt, isNotNull);
      expect(saved.dueAt!.year, _clock.year);
      expect(saved.dueAt!.month, _clock.month);
      expect(saved.dueAt!.day, _clock.day);
      // Pre-assigned at creation but not yet claimed → still Open.
      expect(saved.status, CareTaskStatus.open);
    });
  });

  group('TasksScreen — long-press edit + delete', () {
    testWidgets('long-press opens the card menu with Edit + Delete',
        (tester) async {
      await tasksRepo.upsertTask(_task(id: 't1', title: 'Open task'));
      await pump(tester);

      await tester.longPress(find.byKey(TasksScreen.cardKey('t1')));
      await tester.pumpAndSettle();

      expect(find.byKey(TasksScreen.cardMenuKey), findsOneWidget);
      expect(find.byKey(TasksScreen.cardMenuEditKey), findsOneWidget);
      expect(find.byKey(TasksScreen.cardMenuDeleteKey), findsOneWidget);
    });

    testWidgets('delete removes the card and persists the removal',
        (tester) async {
      await tasksRepo.upsertTask(_task(id: 't1', title: 'Open task'));
      await pump(tester);

      await tester.longPress(find.byKey(TasksScreen.cardKey('t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TasksScreen.cardMenuDeleteKey));
      await tester.pumpAndSettle();

      // Confirm dialog appears; confirm the delete.
      expect(find.byKey(TasksScreen.deleteDialogKey), findsOneWidget);
      await tester.tap(find.byKey(TasksScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      // Gone from the board and from the in-memory repo.
      expect(find.byKey(TasksScreen.cardKey('t1')), findsNothing);
      expect(await tasksRepo.listTasks(), isEmpty);
    });

    testWidgets('cancelling the delete keeps the task', (tester) async {
      await tasksRepo.upsertTask(_task(id: 't1', title: 'Open task'));
      await pump(tester);

      await tester.longPress(find.byKey(TasksScreen.cardKey('t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TasksScreen.cardMenuDeleteKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TasksScreen.deleteCancelKey));
      await tester.pumpAndSettle();

      // Still on disk after a cancelled delete.
      expect((await tasksRepo.listTasks()).single.id, 't1');
    });

    testWidgets('edit updates the task in place — same id, no duplicate',
        (tester) async {
      // A claimed task so we also prove the lifecycle survives the edit.
      await tasksRepo.upsertTask(_task(
        id: 't1',
        title: 'Old title',
        assigneeCaregiverId: _me,
        claimedAt: _clock,
      ));
      await pump(tester);
      await tapSegment(tester, CareTaskStatus.claimed);

      await tester.longPress(find.byKey(TasksScreen.cardKey('t1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TasksScreen.cardMenuEditKey));
      await tester.pumpAndSettle();

      // The edit sheet seeds from the task, then we change the title. (The
      // card is still in the tree under the sheet, so assert the field's own
      // controller rather than a bare text match.)
      expect(find.byKey(TasksScreen.createSheetKey), findsOneWidget);
      final TextField titleField =
          tester.widget<TextField>(find.byKey(TasksScreen.titleFieldKey));
      expect(titleField.controller!.text, 'Old title');
      await tester.enterText(
          find.byKey(TasksScreen.titleFieldKey), 'New title');
      await tester.tap(find.byKey(TasksScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // Exactly one task, same id, new title, still Claimed.
      final List<CareTask> tasks = await tasksRepo.listTasks();
      expect(tasks, hasLength(1));
      expect(tasks.single.id, 't1');
      expect(tasks.single.title, 'New title');
      expect(tasks.single.status, CareTaskStatus.claimed);
      expect(tasks.single.assigneeCaregiverId, _me);
    });
  });
}

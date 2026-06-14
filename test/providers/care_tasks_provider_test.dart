import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_task.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/active_patient_provider.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';
final DateTime _clock = DateTime.utc(2026, 6, 1, 12);

CareTask _task({
  required String id,
  String title = 'Pick up prescription',
  DateTime? dueAt,
  String? assigneeCaregiverId,
  DateTime? claimedAt,
  DateTime? completedAt,
  String patientId = _patientId,
}) =>
    CareTask(
      id: id,
      title: title,
      dueAt: dueAt,
      assigneeCaregiverId: assigneeCaregiverId,
      claimedAt: claimedAt,
      completedAt: completedAt,
      patientId: patientId,
    );

/// Pins the active loved one for the display-scoped providers
/// ([CareTasks.build], [CareTasksView]) without hitting the on-device
/// SQLite file (the default `activePatientIdProvider` reads storage). Tests
/// pass the same id their `_task`s carry so the board sees them.
Override _activePatient([String id = _patientId]) =>
    activePatientIdProvider.overrideWith((Ref ref) async => id);

void main() {
  group('CareTask — derived status', () {
    test('status falls out of the two timestamps', () {
      expect(_task(id: 't').status, CareTaskStatus.open);
      expect(
        _task(id: 't', claimedAt: _clock, assigneeCaregiverId: 'c1').status,
        CareTaskStatus.claimed,
      );
      expect(
        _task(id: 't', claimedAt: _clock, completedAt: _clock).status,
        CareTaskStatus.done,
      );
      // Completed wins even if somehow still flagged claimed.
      expect(_task(id: 't', completedAt: _clock).isDone, isTrue);
    });

    test('claimedBy is true only for the holder of a claimed task', () {
      final CareTask claimed =
          _task(id: 't', claimedAt: _clock, assigneeCaregiverId: 'me');
      expect(claimed.claimedBy('me'), isTrue);
      expect(claimed.claimedBy('someone-else'), isFalse);
      // An open task with a pre-assignment but no claim isn't "claimed by".
      expect(_task(id: 't', assigneeCaregiverId: 'me').claimedBy('me'), isFalse);
    });

    test('round-trips through JSON', () {
      final CareTask task = _task(
        id: 't1',
        title: 'Refill meds',
        dueAt: DateTime.utc(2026, 6, 2, 9),
        assigneeCaregiverId: 'c1',
        claimedAt: _clock,
      );
      expect(CareTask.fromJson(task.toJson()), task);
    });
  });

  group('CareTasksRepository — CRUD', () {
    late CareblazersDatabase db;
    late CareTasksRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = CareTasksRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('task round-trips through the payload blob', () async {
      await repo.upsertTask(_task(
        id: 't1',
        assigneeCaregiverId: 'c1',
        claimedAt: _clock,
      ));

      final CareTask? loaded = await repo.getTask('t1');
      expect(loaded, isNotNull);
      expect(loaded!.assigneeCaregiverId, 'c1');
      expect(loaded.claimedAt, _clock);
    });

    test('listTasks orders dated tasks first, then undated by title',
        () async {
      await repo.upsertTask(
          _task(id: 'late', title: 'Zzz', dueAt: DateTime.utc(2026, 6, 5)));
      await repo.upsertTask(
          _task(id: 'early', title: 'Aaa', dueAt: DateTime.utc(2026, 6, 2)));
      await repo.upsertTask(_task(id: 'undatedB', title: 'Bbb'));
      await repo.upsertTask(_task(id: 'undatedA', title: 'Aaa'));

      final List<CareTask> all = await repo.listTasks();
      expect(
        all.map((CareTask t) => t.id),
        <String>['early', 'late', 'undatedA', 'undatedB'],
      );
    });

    test('deleteTask removes the row; wipeAll truncates the table', () async {
      await repo.upsertTask(_task(id: 't1'));
      await repo.deleteTask('t1');
      expect(await repo.getTask('t1'), isNull);

      await repo.upsertTask(_task(id: 't2'));
      await db.wipeAll();
      expect(await repo.listTasks(), isEmpty);
    });

    test(
        'listTasksForPatient filters to one patient; listTasks stays '
        'unfiltered (for sync)', () async {
      await repo.upsertTask(_task(id: 'mine', patientId: _patientId));
      await repo.upsertTask(_task(id: 'theirs', patientId: 'other-patient'));

      // The display read sees only the active patient's task…
      final List<CareTask> mine = await repo.listTasksForPatient(_patientId);
      expect(mine.map((CareTask t) => t.id), <String>['mine']);

      // …while the unfiltered read (what resyncAllLocal walks) sees BOTH, so
      // sync still pushes every local row regardless of patient.
      final List<CareTask> all = await repo.listTasks();
      expect(all.map((CareTask t) => t.id).toSet(),
          <String>{'mine', 'theirs'});
    });

    test('restampPatient re-files legacy rows and is a no-op when from==to',
        () async {
      await repo.upsertTask(_task(id: 'legacy1', patientId: 'demo-patient-mary'));
      await repo.upsertTask(_task(id: 'legacy2', patientId: 'demo-patient-mary'));
      await repo.upsertTask(_task(id: 'already', patientId: 'patient-new'));

      final int moved =
          await repo.restampPatient('demo-patient-mary', 'patient-new');
      expect(moved, 2);
      expect(await repo.listTasksForPatient('demo-patient-mary'), isEmpty);
      expect(
        (await repo.listTasksForPatient('patient-new'))
            .map((CareTask t) => t.id)
            .toSet(),
        <String>{'legacy1', 'legacy2', 'already'},
      );

      // Re-running with identical ids moves nothing.
      expect(
        await repo.restampPatient('patient-new', 'patient-new'),
        0,
      );
    });
  });

  group('CareTasks notifier — state machine', () {
    late CareblazersDatabase db;
    late CareTasksRepository repo;

    ProviderContainer makeContainer() {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          careTasksRepositoryProvider.overrideWithValue(repo),
          careTasksClockProvider.overrideWithValue(() => _clock),
          _activePatient(),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = CareTasksRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('addTask lands a task in the open pool', () async {
      final ProviderContainer container = makeContainer();
      await container.read(careTasksProvider.future);

      await container
          .read(careTasksProvider.notifier)
          .addTask(_task(id: 't1'));

      final List<CareTask> tasks =
          await container.read(careTasksProvider.future);
      expect(tasks.single.status, CareTaskStatus.open);
    });

    test('claim stamps claimedAt + assignee and moves to Claimed', () async {
      await repo.upsertTask(_task(id: 't1'));
      final ProviderContainer container = makeContainer();
      await container.read(careTasksProvider.future);

      await container.read(careTasksProvider.notifier).claim('t1', 'me');

      final CareTask task = (await container.read(careTasksProvider.future))
          .firstWhere((CareTask t) => t.id == 't1');
      expect(task.status, CareTaskStatus.claimed);
      expect(task.assigneeCaregiverId, 'me');
      expect(task.claimedAt, _clock);
      expect(task.claimedBy('me'), isTrue);
    });

    test('claim is a no-op on an already-claimed task', () async {
      await repo.upsertTask(
          _task(id: 't1', claimedAt: _clock, assigneeCaregiverId: 'first'));
      final ProviderContainer container = makeContainer();
      await container.read(careTasksProvider.future);

      await container.read(careTasksProvider.notifier).claim('t1', 'second');

      final CareTask task = (await container.read(careTasksProvider.future))
          .firstWhere((CareTask t) => t.id == 't1');
      expect(task.assigneeCaregiverId, 'first');
    });

    test('unclaim clears the claim back to the open pool', () async {
      await repo.upsertTask(
          _task(id: 't1', claimedAt: _clock, assigneeCaregiverId: 'me'));
      final ProviderContainer container = makeContainer();
      await container.read(careTasksProvider.future);

      await container.read(careTasksProvider.notifier).unclaim('t1');

      final CareTask task = (await container.read(careTasksProvider.future))
          .firstWhere((CareTask t) => t.id == 't1');
      expect(task.status, CareTaskStatus.open);
      expect(task.assigneeCaregiverId, isNull);
      expect(task.claimedAt, isNull);
    });

    test('complete stamps completedAt and moves to Done', () async {
      await repo.upsertTask(
          _task(id: 't1', claimedAt: _clock, assigneeCaregiverId: 'me'));
      final ProviderContainer container = makeContainer();
      await container.read(careTasksProvider.future);

      await container.read(careTasksProvider.notifier).complete('t1');

      final CareTask task = (await container.read(careTasksProvider.future))
          .firstWhere((CareTask t) => t.id == 't1');
      expect(task.status, CareTaskStatus.done);
      expect(task.completedAt, _clock);
    });

    test('complete is a no-op once a task is already done', () async {
      final DateTime original = DateTime.utc(2026, 1, 1);
      await repo.upsertTask(_task(id: 't1', completedAt: original));
      final ProviderContainer container = makeContainer();
      await container.read(careTasksProvider.future);

      await container.read(careTasksProvider.notifier).complete('t1');

      final CareTask task = (await container.read(careTasksProvider.future))
          .firstWhere((CareTask t) => t.id == 't1');
      expect(task.completedAt, original);
    });

    test('removeTask deletes the task', () async {
      await repo.upsertTask(_task(id: 't1'));
      final ProviderContainer container = makeContainer();
      await container.read(careTasksProvider.future);

      await container.read(careTasksProvider.notifier).removeTask('t1');

      expect(await container.read(careTasksProvider.future), isEmpty);
    });

    test('the board shows only the ACTIVE patient — another loved one\'s '
        'task is hidden', () async {
      // Two tasks under two different loved ones; the active patient is
      // _patientId (pinned by makeContainer's _activePatient override).
      await repo.upsertTask(_task(id: 'mine', patientId: _patientId));
      await repo.upsertTask(_task(id: 'theirs', patientId: 'other-patient'));

      final List<CareTask> board =
          await makeContainer().read(careTasksProvider.future);

      expect(board.map((CareTask t) => t.id), <String>['mine']);
    });
  });

  group('careTasksView — join with assignees', () {
    late CareblazersDatabase db;
    late CareTasksRepository tasksRepo;
    late CareCircleRepository circleRepo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      tasksRepo = CareTasksRepository(db);
      circleRepo = CareCircleRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('resolves the assignee caregiver for a claimed task', () async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await tasksRepo.upsertTask(
          _task(id: 't1', claimedAt: _clock, assigneeCaregiverId: 'c1'));
      await tasksRepo.upsertTask(_task(id: 't2'));

      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          careTasksRepositoryProvider.overrideWithValue(tasksRepo),
          careCircleRepositoryProvider.overrideWithValue(circleRepo),
          careTasksClockProvider.overrideWithValue(() => _clock),
          _activePatient(),
        ],
      );
      addTearDown(container.dispose);

      final List<CareTaskCard> cards =
          await container.read(careTasksViewProvider.future);

      final CareTaskCard claimed =
          cards.firstWhere((CareTaskCard c) => c.task.id == 't1');
      final CareTaskCard open =
          cards.firstWhere((CareTaskCard c) => c.task.id == 't2');
      expect(claimed.assignee?.displayName, 'Maria Lopez');
      expect(open.assignee, isNull);
    });
  });
}

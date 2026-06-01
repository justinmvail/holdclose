import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/care_task.dart';
import '../models/caregiver.dart';
import 'care_circle_provider.dart';

part 'care_tasks_provider.g.dart';

/// Logical patient id new tasks are stamped with (TASKS.md Phase 14.30) —
/// the single-install loved one. Same fallback constant the calendar +
/// care-circle forms use.
const String careTasksPatientId = 'demo-patient-mary';

/// Stand-in for the signed-in caregiver's id until real per-device auth
/// lands (TASKS.md Phase 14.30). Claiming a task stamps this id, and the
/// task board compares against it to decide which claimed cards show the
/// Complete + Unclaim actions ("claimed by me") versus a read-only
/// assignee. Overridable so tests pin a known "me".
@Riverpod(keepAlive: true)
String currentCaregiverId(Ref ref) => 'demo-caregiver-me';

/// Persistence for the Care Team task board (TASKS.md Phase 14.30).
///
/// Same blob-with-lifted-keys pattern [CareEventsRepository] uses — the
/// freezed [CareTask] serialises into the row's `payload`, with
/// [CareTasksTable.dueAtMs] lifted out so the board can order by due time
/// without decoding every blob. Tests build a repository directly against
/// `CareblazersDatabase(NativeDatabase.memory())` so each test gets an
/// isolated DB.
class CareTasksRepository {
  CareTasksRepository(this._db);

  final CareblazersDatabase _db;

  /// Close the underlying database. The riverpod provider wires this to
  /// `ref.onDispose`.
  Future<void> close() => _db.close();

  /// Insert-or-replace [task] by id.
  Future<void> upsertTask(CareTask task) async {
    await _db.into(_db.careTasksTable).insertOnConflictUpdate(
          CareTasksTableCompanion.insert(
            id: task.id,
            patientId: task.patientId,
            dueAtMs: Value<int?>(task.dueAt?.millisecondsSinceEpoch),
            payload: jsonEncode(task.toJson()),
          ),
        );
  }

  /// Drop the task with this id. No-op if absent.
  Future<void> deleteTask(String id) async {
    await (_db.delete(_db.careTasksTable)..where((t) => t.id.equals(id))).go();
  }

  /// One task by id, or null if absent.
  Future<CareTask?> getTask(String id) async {
    final CareTasksTableData? row = await (_db.select(_db.careTasksTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return CareTask.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  /// Every task, dated ones first (earliest due first) then the undated
  /// ones. SQLite sorts NULLs first under `ASC`, so the due-time order is
  /// re-applied in Dart to keep undated tasks at the tail deterministically.
  Future<List<CareTask>> listTasks() async {
    final List<CareTasksTableData> rows =
        await _db.select(_db.careTasksTable).get();
    final List<CareTask> tasks = rows
        .map((CareTasksTableData r) =>
            CareTask.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
    tasks.sort(_byDueThenTitle);
    return tasks;
  }
}

/// Order tasks earliest-due first, undated last, then alphabetically by
/// title so the board stays stable across reads.
int _byDueThenTitle(CareTask a, CareTask b) {
  final DateTime? da = a.dueAt;
  final DateTime? db = b.dueAt;
  if (da != null && db != null) {
    final int byDue = da.compareTo(db);
    if (byDue != 0) return byDue;
  } else if (da != null) {
    return -1;
  } else if (db != null) {
    return 1;
  }
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// Riverpod-wired singleton (TASKS.md Phase 14.30). The task board reaches
/// for [careTasksRepositoryProvider] and never sees the concrete drift
/// database — same indirection [careCircleRepositoryProvider] uses.
@Riverpod(keepAlive: true)
CareTasksRepository careTasksRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return CareTasksRepository(db);
}

/// Alias for consumers — matches the `careTasksRepositoryProvider` name the
/// task board reaches for.
final CareTasksRepositoryBackendProvider careTasksRepositoryProvider =
    careTasksRepositoryBackendProvider;

/// Wall clock used to stamp claim + complete times. Overridable so tests
/// pin a fixed time and the state-machine transitions stay deterministic —
/// same pattern [careCircleClockProvider] uses.
@Riverpod(keepAlive: true)
DateTime Function() careTasksClock(Ref ref) => DateTime.now;

/// The loved one's shared task board (TASKS.md Phase 14.30).
///
/// `build()` loads every task, due-ordered. The mutators ([addTask] /
/// [claim] / [unclaim] / [complete] / [removeTask]) write through
/// [careTasksRepositoryProvider] and re-read so the screen reflects the
/// change without a manual invalidate — same shape as [CareCircle].
@Riverpod(keepAlive: true)
class CareTasks extends _$CareTasks {
  @override
  Future<List<CareTask>> build() async {
    final CareTasksRepository repo = ref.watch(careTasksRepositoryProvider);
    return repo.listTasks();
  }

  /// Create (or replace) a task, then refresh.
  Future<void> addTask(CareTask task) =>
      _mutate((CareTasksRepository repo) => repo.upsertTask(task));

  /// Claim an open task for [caregiverId] — stamps [CareTask.claimedAt] and
  /// sets the assignee. No-op if the task is gone, already claimed, or
  /// already done.
  Future<void> claim(String taskId, String caregiverId) =>
      _mutate((CareTasksRepository repo) async {
        final CareTask? existing = await repo.getTask(taskId);
        if (existing == null ||
            existing.completedAt != null ||
            existing.claimedAt != null) {
          return;
        }
        final DateTime now = ref.read(careTasksClockProvider)();
        await repo.upsertTask(existing.copyWith(
          assigneeCaregiverId: caregiverId,
          claimedAt: now,
        ));
      });

  /// Return a claimed task to the open pool — clears the claim + assignee.
  /// No-op if the task is gone or already done.
  Future<void> unclaim(String taskId) =>
      _mutate((CareTasksRepository repo) async {
        final CareTask? existing = await repo.getTask(taskId);
        if (existing == null || existing.completedAt != null) return;
        await repo.upsertTask(existing.copyWith(
          assigneeCaregiverId: null,
          claimedAt: null,
        ));
      });

  /// Mark a task done — stamps [CareTask.completedAt]. No-op if the task is
  /// gone or already done.
  Future<void> complete(String taskId) =>
      _mutate((CareTasksRepository repo) async {
        final CareTask? existing = await repo.getTask(taskId);
        if (existing == null || existing.completedAt != null) return;
        final DateTime now = ref.read(careTasksClockProvider)();
        await repo.upsertTask(existing.copyWith(completedAt: now));
      });

  /// Delete a task outright, then refresh.
  Future<void> removeTask(String taskId) =>
      _mutate((CareTasksRepository repo) => repo.deleteTask(taskId));

  Future<void> _mutate(
    Future<void> Function(CareTasksRepository repo) op,
  ) async {
    final CareTasksRepository repo = ref.read(careTasksRepositoryProvider);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return repo.listTasks();
    });
  }
}

/// One task paired with its resolved assignee, if any (TASKS.md Phase
/// 14.30).
///
/// The board renders one of these per card — the task supplies the title /
/// due time / lifecycle, and [assignee] (looked up softly from the care
/// circle) supplies the avatar + name when the task is claimed. Bundled so
/// the screen consumes a single joined shape rather than re-joining two
/// lists itself.
@immutable
class CareTaskCard {
  const CareTaskCard({required this.task, this.assignee});

  final CareTask task;

  /// The caregiver who holds the task, when it resolves to a care-circle
  /// row; null for an unclaimed task or one claimed by someone without a
  /// roster entry (e.g. the signed-in caregiver before they're listed).
  final Caregiver? assignee;
}

/// Caregivers that can be assigned a task — the care circle's roster
/// (TASKS.md Phase 14.30). Drives the create sheet's optional-assignee
/// picker and the card's assignee resolution.
@riverpod
Future<List<Caregiver>> assignableCaregivers(Ref ref) async {
  final CareCircleRepository repo = ref.watch(careCircleRepositoryProvider);
  return repo.listCaregivers();
}

/// The joined task-board view the screen watches (TASKS.md Phase 14.30).
///
/// Watches the [CareTasks] notifier (not the repository directly) so an
/// add / claim / unclaim / complete saved through the notifier refreshes
/// the view without a manual invalidate, and joins each task to its
/// assignee via [assignableCaregivers]. Tests override this provider
/// wholesale for the display + golden cases, and drive the notifier +
/// repository for the state-machine cases.
@riverpod
Future<List<CareTaskCard>> careTasksView(Ref ref) async {
  final List<CareTask> tasks = await ref.watch(careTasksProvider.future);
  final List<Caregiver> caregivers =
      await ref.watch(assignableCaregiversProvider.future);
  final Map<String, Caregiver> byId = <String, Caregiver>{
    for (final Caregiver c in caregivers) c.id: c,
  };
  return <CareTaskCard>[
    for (final CareTask task in tasks)
      CareTaskCard(
        task: task,
        assignee: task.assigneeCaregiverId == null
            ? null
            : byId[task.assigneeCaregiverId],
      ),
  ];
}

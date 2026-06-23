import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/care_task.dart';
import '../models/caregiver.dart';
import '../services/sync_sink.dart';
import 'active_patient_provider.dart';
import 'auth_provider.dart';
import 'care_circle_provider.dart';
import 'care_events_provider.dart' show fallbackPatientId;

part 'care_tasks_provider.g.dart';

/// Logical patient id new tasks are stamped with (TASKS.md Phase 14.30) —
/// the single-install loved one. Aliases the shared neutral
/// [fallbackPatientId] so there's one source of truth for the value.
const String careTasksPatientId = fallbackPatientId;

/// Fallback caregiver id used only when no real user is signed in (the
/// demo / signed-out path). Real signed-in installs resolve to the
/// caregiver's actual user id via [currentCaregiverId].
const String fallbackCaregiverId = 'demo-caregiver-me';

/// The signed-in caregiver's id (TASKS.md Phase 14.30). Claiming a task or
/// naming an expense payer stamps this id, and the task board compares
/// against it to decide which claimed cards show the Complete + Unclaim
/// actions ("claimed by me") versus a read-only assignee.
///
/// Resolves to the REAL signed-in user's id, read synchronously from the
/// user persisted at launch ([preloadedAlphaUser], loaded in `main()`
/// before `runApp`). When signed out — the demo, widget tests, or a
/// first launch before any sign-in — it falls back to
/// [fallbackCaregiverId] so attribution stays stable. Overridable so
/// tests pin a known "me".
@Riverpod(keepAlive: true)
String currentCaregiverId(Ref ref) =>
    preloadedAlphaUser?.id ?? fallbackCaregiverId;

/// Persistence for the Care Team task board (TASKS.md Phase 14.30).
///
/// Same blob-with-lifted-keys pattern [CareEventsRepository] uses — the
/// freezed [CareTask] serialises into the row's `payload`, with
/// [CareTasksTable.dueAtMs] lifted out so the board can order by due time
/// without decoding every blob. Tests build a repository directly against
/// `HoldcloseDatabase(NativeDatabase.memory())` so each test gets an
/// isolated DB.
class CareTasksRepository with SyncSinkHost {
  CareTasksRepository(this._db);

  final HoldcloseDatabase _db;

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
    emitUpsert('care_tasks', task.id, task.toJson());
  }

  /// Drop the task with this id. No-op if absent.
  Future<void> deleteTask(String id) async {
    await (_db.delete(_db.careTasksTable)..where((t) => t.id.equals(id))).go();
    emitDelete('care_tasks', id);
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
  ///
  /// UNFILTERED across patients on purpose — the sync engine
  /// ([SyncController.resyncAllLocal]) walks this to push EVERY local row up
  /// regardless of which loved one is active. The board's DISPLAY read is
  /// [listTasksForPatient]; don't swap one for the other.
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

  /// Tasks filed under [patientId] only, same ordering as [listTasks]
  /// (multi-patient display scoping, Issue #6).
  ///
  /// The board / calendar / timeline read THIS so a caregiver with more than
  /// one loved one on file (e.g. left over from the earlier duplicate-patient
  /// bug) never sees another person's tasks. Filters on the lifted
  /// [CareTasksTable.patientId] column. Sync still uses the unfiltered
  /// [listTasks].
  Future<List<CareTask>> listTasksForPatient(String patientId) async {
    final List<CareTasksTableData> rows = await (_db.select(_db.careTasksTable)
          ..where((t) => t.patientId.equals(patientId)))
        .get();
    final List<CareTask> tasks = rows
        .map((CareTasksTableData r) =>
            CareTask.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
    tasks.sort(_byDueThenTitle);
    return tasks;
  }

  /// Re-file every task currently stamped [from] under [to], returning the
  /// number of rows moved (the one-time multi-patient migration, Issue #6).
  ///
  /// Each moved row round-trips through [upsertTask] so the lifted
  /// [CareTasksTable.patientId] column is rewritten AND the change re-emits
  /// through the sync sink (acceptable — LWW resolves it). A no-op when
  /// [from] == [to].
  Future<int> restampPatient(String from, String to) async {
    if (from == to) return 0;
    final List<CareTask> tasks = await listTasksForPatient(from);
    for (final CareTask task in tasks) {
      await upsertTask(task.copyWith(patientId: to));
    }
    return tasks.length;
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
  final HoldcloseDatabase db = HoldcloseDatabase.open();
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
    // Scope the board to the active loved one (multi-patient, Issue #6) so a
    // caregiver with several people on file sees only the selected person's
    // tasks. With one loved one [activePatientIdProvider] resolves to that
    // sole id, identical to the old unfiltered read.
    final String patientId = await ref.watch(activePatientIdProvider.future);
    return repo.listTasksForPatient(patientId);
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
    final String patientId = await ref.read(activePatientIdProvider.future);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return repo.listTasksForPatient(patientId);
    });
  }
}

/// Child-task counts per routine (unified task/routine model, 2026-06-06).
///
/// Maps a routine id to how many child [CareTask]s are bundled under it.
/// The Routines list reads this to show "· N tasks" next to each routine.
/// Watches the [CareTasks] notifier so an add / reconcile through the
/// routine form refreshes the count without a manual invalidate.
@riverpod
Future<Map<String, int>> routineTaskCounts(Ref ref) async {
  final List<CareTask> tasks = await ref.watch(careTasksProvider.future);
  final Map<String, int> counts = <String, int>{};
  for (final CareTask task in tasks) {
    final String? routineId = task.routineId;
    if (routineId == null) continue;
    counts[routineId] = (counts[routineId] ?? 0) + 1;
  }
  return counts;
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
///
/// Only **standalone** tasks (`routineId == null`) surface on the team
/// board (unified task/routine model, 2026-06-06) — routine-bound tasks
/// live under their routine in Medical → Routines, not on the loose board.
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
      if (task.routineId == null)
        CareTaskCard(
          task: task,
          assignee: task.assigneeCaregiverId == null
              ? null
              : byId[task.assigneeCaregiverId],
        ),
  ];
}

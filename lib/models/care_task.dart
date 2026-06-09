import 'package:freezed_annotation/freezed_annotation.dart';

part 'care_task.freezed.dart';
part 'care_task.g.dart';

/// Where a [CareTask] sits in its lifecycle (TASKS.md Phase 14.30,
/// BUILD_SPEC.md §5.14).
///
/// Derived from the two timestamps — never stored directly — so the
/// segmented filter (Open / Claimed / Done) and the per-card action set
/// read off one source of truth:
/// - [open] — nobody has picked it up yet ([CareTask.claimedAt] null,
///   [CareTask.completedAt] null).
/// - [claimed] — a caregiver owns it but it isn't finished
///   ([CareTask.claimedAt] set, [CareTask.completedAt] null).
/// - [done] — finished ([CareTask.completedAt] set), regardless of who
///   held it.
enum CareTaskStatus {
  open,
  claimed,
  done,
}

/// One shared to-do on the Care Team task board (TASKS.md Phase 14.30,
/// BUILD_SPEC.md §5.14).
///
/// A caregiver creates a task ([title] + optional [body] + optional
/// [dueAt]), optionally pre-assigning it to someone ([assigneeCaregiverId]).
/// Any caregiver can then **claim** it (which stamps [claimedAt] and sets
/// [assigneeCaregiverId] to the claimer), **unclaim** it (clears both back
/// to the open pool), or **complete** it (stamps [completedAt]). The
/// derived [CareTaskX.status] drives the screen's segmented filter and the
/// action buttons each card shows.
///
/// [patientId] is a logical link to the single-row patients table, carried
/// explicitly so a future multi-patient model lands without a migration —
/// mirroring the care-event + care-circle models.
@freezed
abstract class CareTask with _$CareTask {
  const factory CareTask({
    required String id,
    required String title,

    /// Optional longer description shown on the card / create sheet.
    String? body,

    /// The routine this task belongs to, or null for a standalone one-off.
    /// A routine "bundles" its tasks the way a dose window bundles
    /// medications (unified task/routine model, 2026-06-06): a lone task
    /// rides the schedule on its own; grouped tasks render under their
    /// routine header. Stored in the JSON payload, so no DB migration.
    String? routineId,

    /// Optional due time. Null tasks sort after dated ones within a
    /// segment.
    DateTime? dueAt,

    /// Who currently owns the task — set when pre-assigned at creation or
    /// when a caregiver claims it; null in the open pool.
    String? assigneeCaregiverId,

    /// When the task was claimed; null while it sits in the open pool.
    DateTime? claimedAt,

    /// When the task was completed; null until it's done.
    DateTime? completedAt,
    required String patientId,
  }) = _CareTask;

  factory CareTask.fromJson(Map<String, dynamic> json) =>
      _$CareTaskFromJson(json);
}

/// Status + assignment helpers for [CareTask], kept off the freezed factory
/// so the generated model stays a pure data class.
extension CareTaskX on CareTask {
  /// Lifecycle bucket derived from the two timestamps (see
  /// [CareTaskStatus]). Completed wins over claimed wins over open.
  CareTaskStatus get status {
    if (completedAt != null) return CareTaskStatus.done;
    if (claimedAt != null) return CareTaskStatus.claimed;
    return CareTaskStatus.open;
  }

  bool get isOpen => status == CareTaskStatus.open;
  bool get isClaimed => status == CareTaskStatus.claimed;
  bool get isDone => status == CareTaskStatus.done;

  /// True when the task isn't bundled under a routine — a one-off that
  /// rides the schedule on its own (when it has a [dueAt]).
  bool get isStandalone => routineId == null;

  /// True when [caregiverId] is the caregiver who currently holds the task
  /// — the gate the screen uses to show Complete + Unclaim only on a
  /// task claimed by the signed-in caregiver.
  bool claimedBy(String caregiverId) =>
      claimedAt != null && assigneeCaregiverId == caregiverId;
}

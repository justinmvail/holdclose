import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/care_shift.dart';
import '../models/caregiver.dart';
import '../services/sync_sink.dart';
import 'active_patient_provider.dart';
import 'care_circle_provider.dart';
import 'care_events_provider.dart' show fallbackPatientId;

part 'care_shifts_provider.g.dart';

/// Logical patient id new shifts are stamped with (TASKS.md Phase 14.31) —
/// the single-install loved one. Aliases the shared neutral
/// [fallbackPatientId] so there's one source of truth for the value.
const String careShiftsPatientId = fallbackPatientId;

/// A half-open interval `[start, end)` on the coverage timeline (TASKS.md
/// Phase 14.31).
///
/// Used for both a day's covered spans and the gaps between them. Kept
/// model-free (no [CareShift] back-reference) so the gap math composes — a
/// covered span merged from two caregivers' shifts no longer belongs to
/// either one.
@immutable
class DayInterval {
  const DayInterval({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  /// The interval's length. Always non-negative for intervals the gap math
  /// produces (they're clamped to the day window before construction).
  Duration get duration => end.difference(start);

  @override
  bool operator ==(Object other) =>
      other is DayInterval && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'DayInterval($start..$end)';
}

/// One day's coverage summary for the 7-day strip (TASKS.md Phase 14.31).
///
/// Bundles everything the day row renders: the [day] (its local midnight),
/// the [shifts] whose window intersects it (sorted by start), and the
/// [gaps] — the spans of the day no shift covers. The screen reads
/// [caregiverCount] + [uncovered] straight off this for the caption ("3
/// caregivers · 2h uncovered: 6am–8am").
@immutable
class DayCoverage {
  const DayCoverage({
    required this.day,
    required this.shifts,
    required this.gaps,
  });

  /// Local midnight opening the day this summary covers.
  final DateTime day;

  /// The shifts whose `[start, end)` window intersects [day], sorted by
  /// start. A midnight-spanning shift appears on both days it touches.
  final List<CareShift> shifts;

  /// The uncovered spans within `[day, day + 1)`, in order. Empty when the
  /// day is fully covered; a single full-day interval when nothing covers
  /// it.
  final List<DayInterval> gaps;

  /// Local midnight closing the day (the start of the next day).
  DateTime get dayEnd => day.add(const Duration(days: 1));

  /// Distinct caregivers with a shift touching the day.
  int get caregiverCount =>
      shifts.map((CareShift s) => s.caregiverId).toSet().length;

  /// Total uncovered time across all [gaps].
  Duration get uncovered =>
      gaps.fold(Duration.zero, (Duration sum, DayInterval g) => sum + g.duration);

  /// True when no shift leaves a gap — the whole day is covered.
  bool get isFullyCovered => gaps.isEmpty;
}

/// Local midnight on the same calendar day as [t] (strips time-of-day).
DateTime _dayStart(DateTime t) => DateTime(t.year, t.month, t.day);

/// Build the [DayCoverage] for [day] from [shifts] (TASKS.md Phase 14.31).
///
/// Pure — no DB, no clock. Clamps each intersecting shift to the day's
/// `[midnight, next-midnight)` window, merges the clamped spans across
/// caregivers, and takes the complement for the gaps. A shift that starts
/// before or ends after the day contributes only its in-day slice, so a
/// 10pm–6am shift covers two days' worth of strip correctly.
DayCoverage coverageFor(Iterable<CareShift> shifts, DateTime day) {
  final DateTime start = _dayStart(day);
  final DateTime end = start.add(const Duration(days: 1));

  final List<CareShift> touching = shifts
      .where((CareShift s) => s.start.isBefore(end) && s.end.isAfter(start))
      .toList()
    ..sort((CareShift a, CareShift b) => a.start.compareTo(b.start));

  return DayCoverage(
    day: start,
    shifts: touching,
    gaps: _gaps(touching, start, end),
  );
}

/// The uncovered intervals within [day]'s window, given [shifts] (TASKS.md
/// Phase 14.31).
///
/// The screen's coverage bar reads colored bands off the shifts and red
/// striped bands off these gaps. Convenience wrapper over [coverageFor] for
/// the cases (and tests) that only want the gaps.
List<DayInterval> gapsFor(Iterable<CareShift> shifts, DateTime day) =>
    coverageFor(shifts, day).gaps;

/// Complement of the merged, day-clamped shift spans within
/// `[dayStart, dayEnd)`.
List<DayInterval> _gaps(
  List<CareShift> shifts,
  DateTime dayStart,
  DateTime dayEnd,
) {
  // Clamp each shift to the day window; drop zero-length slices.
  final List<DayInterval> covered = <DayInterval>[];
  for (final CareShift s in shifts) {
    final DateTime cs = s.start.isBefore(dayStart) ? dayStart : s.start;
    final DateTime ce = s.end.isAfter(dayEnd) ? dayEnd : s.end;
    if (ce.isAfter(cs)) covered.add(DayInterval(start: cs, end: ce));
  }
  covered.sort((DayInterval a, DayInterval b) => a.start.compareTo(b.start));

  // Merge overlapping or adjacent spans (an end touching the next start
  // leaves no gap, so `isAfter` — not `isBefore` — is the split test).
  final List<DayInterval> merged = <DayInterval>[];
  for (final DayInterval iv in covered) {
    if (merged.isEmpty || iv.start.isAfter(merged.last.end)) {
      merged.add(iv);
    } else if (iv.end.isAfter(merged.last.end)) {
      merged[merged.length - 1] =
          DayInterval(start: merged.last.start, end: iv.end);
    }
  }

  // Take the complement within the day window.
  final List<DayInterval> gaps = <DayInterval>[];
  DateTime cursor = dayStart;
  for (final DayInterval iv in merged) {
    if (iv.start.isAfter(cursor)) {
      gaps.add(DayInterval(start: cursor, end: iv.start));
    }
    if (iv.end.isAfter(cursor)) cursor = iv.end;
  }
  if (cursor.isBefore(dayEnd)) {
    gaps.add(DayInterval(start: cursor, end: dayEnd));
  }
  return gaps;
}

/// Persistence for the Care Team shift board (TASKS.md Phase 14.31).
///
/// Same blob-with-lifted-keys pattern [CareTasksRepository] uses — the
/// freezed [CareShift] serialises into the row's `payload`, with
/// [CareShiftsTable.startMs] / [CareShiftsTable.endMs] lifted out so the
/// day strip can window without decoding every blob. Tests build a
/// repository directly against `HoldcloseDatabase(NativeDatabase.memory())`
/// so each test gets an isolated DB.
class CareShiftsRepository with SyncSinkHost {
  CareShiftsRepository(this._db);

  final HoldcloseDatabase _db;

  /// Close the underlying database. The riverpod provider wires this to
  /// `ref.onDispose`.
  Future<void> close() => _db.close();

  /// Insert-or-replace [shift] by id.
  Future<void> upsertShift(CareShift shift) async {
    await _db.into(_db.careShiftsTable).insertOnConflictUpdate(
          CareShiftsTableCompanion.insert(
            id: shift.id,
            patientId: shift.patientId,
            startMs: shift.start.millisecondsSinceEpoch,
            endMs: shift.end.millisecondsSinceEpoch,
            payload: jsonEncode(shift.toJson()),
          ),
        );
    emitUpsert('care_shifts', shift.id, shift.toJson());
  }

  /// Drop the shift with this id. No-op if absent.
  Future<void> deleteShift(String id) async {
    await (_db.delete(_db.careShiftsTable)..where((t) => t.id.equals(id))).go();
    emitDelete('care_shifts', id);
  }

  /// One shift by id, or null if absent.
  Future<CareShift?> getShift(String id) async {
    final CareShiftsTableData? row = await (_db.select(_db.careShiftsTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return CareShift.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  /// Every shift, earliest start first.
  ///
  /// UNFILTERED across patients on purpose — the sync engine
  /// ([SyncController.resyncAllLocal]) walks this to push EVERY local row up
  /// regardless of which loved one is active. The strip's DISPLAY read is
  /// [listShiftsForPatient].
  Future<List<CareShift>> listShifts() async {
    final List<CareShiftsTableData> rows = await (_db
            .select(_db.careShiftsTable)
          ..orderBy(<OrderClauseGenerator<$CareShiftsTableTable>>[
            (t) => OrderingTerm(expression: t.startMs, mode: OrderingMode.asc),
          ]))
        .get();
    return rows
        .map((CareShiftsTableData r) =>
            CareShift.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  /// Shifts filed under [patientId] only, earliest start first
  /// (multi-patient display scoping, Issue #6).
  ///
  /// The coverage strip reads THIS so a caregiver with more than one loved
  /// one on file never sees another person's shifts. Filters on the lifted
  /// [CareShiftsTable.patientId] column. Sync still uses the unfiltered
  /// [listShifts].
  Future<List<CareShift>> listShiftsForPatient(String patientId) async {
    final List<CareShiftsTableData> rows = await (_db
            .select(_db.careShiftsTable)
          ..where((t) => t.patientId.equals(patientId))
          ..orderBy(<OrderClauseGenerator<$CareShiftsTableTable>>[
            (t) => OrderingTerm(expression: t.startMs, mode: OrderingMode.asc),
          ]))
        .get();
    return rows
        .map((CareShiftsTableData r) =>
            CareShift.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  /// Re-file every shift currently stamped [from] under [to], returning the
  /// number of rows moved (the one-time multi-patient migration, Issue #6).
  ///
  /// Each moved row round-trips through [upsertShift] so the lifted
  /// [CareShiftsTable.patientId] column is rewritten AND the change re-emits
  /// through the sync sink. A no-op when [from] == [to].
  Future<int> restampPatient(String from, String to) async {
    if (from == to) return 0;
    final List<CareShift> shifts = await listShiftsForPatient(from);
    for (final CareShift shift in shifts) {
      await upsertShift(shift.copyWith(patientId: to));
    }
    return shifts.length;
  }
}

/// Riverpod-wired singleton (TASKS.md Phase 14.31). The shifts screen
/// reaches for [careShiftsRepositoryProvider] and never sees the concrete
/// drift database — same indirection [careTasksRepositoryProvider] uses.
@Riverpod(keepAlive: true)
CareShiftsRepository careShiftsRepositoryBackend(Ref ref) {
  final HoldcloseDatabase db = HoldcloseDatabase.open();
  ref.onDispose(db.close);
  return CareShiftsRepository(db);
}

/// Alias for consumers — matches the `careShiftsRepositoryProvider` name
/// the shifts screen reaches for.
final CareShiftsRepositoryBackendProvider careShiftsRepositoryProvider =
    careShiftsRepositoryBackendProvider;

/// Wall clock used to anchor the 7-day strip on "today" and seed the
/// schedule sheet's default times. Overridable so tests + goldens pin a
/// fixed "now" and the visible week stays stable — same pattern
/// [careTasksClockProvider] uses.
@Riverpod(keepAlive: true)
DateTime Function() careShiftsClock(Ref ref) => DateTime.now;

/// The loved one's shift board (TASKS.md Phase 14.31).
///
/// `build()` loads every shift, earliest first. The mutators ([addShift] /
/// [removeShift]) write through [careShiftsRepositoryProvider] and re-read
/// so the screen reflects the change without a manual invalidate — same
/// shape as [CareTasks].
@Riverpod(keepAlive: true)
class CareShifts extends _$CareShifts {
  @override
  Future<List<CareShift>> build() async {
    final CareShiftsRepository repo = ref.watch(careShiftsRepositoryProvider);
    // Scope the coverage strip to the active loved one (multi-patient, Issue
    // #6). With one loved one [activePatientIdProvider] resolves to that sole
    // id, identical to the old unfiltered read.
    final String patientId = await ref.watch(activePatientIdProvider.future);
    return repo.listShiftsForPatient(patientId);
  }

  /// Create (or replace) a shift, then refresh.
  Future<void> addShift(CareShift shift) =>
      _mutate((CareShiftsRepository repo) => repo.upsertShift(shift));

  /// Delete a shift outright, then refresh.
  Future<void> removeShift(String shiftId) =>
      _mutate((CareShiftsRepository repo) => repo.deleteShift(shiftId));

  Future<void> _mutate(
    Future<void> Function(CareShiftsRepository repo) op,
  ) async {
    final CareShiftsRepository repo = ref.read(careShiftsRepositoryProvider);
    final String patientId = await ref.read(activePatientIdProvider.future);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return repo.listShiftsForPatient(patientId);
    });
  }
}

/// Caregivers a shift can be assigned to — the care circle's roster
/// (TASKS.md Phase 14.31). Drives the schedule sheet's caregiver picker and
/// the bar's per-caregiver color + name resolution.
@riverpod
Future<List<Caregiver>> schedulableCaregivers(Ref ref) async {
  final CareCircleRepository repo = ref.watch(careCircleRepositoryProvider);
  return repo.listCaregivers();
}

/// The 7-day coverage strip the screen watches (TASKS.md Phase 14.31).
///
/// Watches the [CareShifts] notifier (not the repository directly) so an
/// add / remove saved through the notifier refreshes the strip without a
/// manual invalidate, and folds the shift list into one [DayCoverage] per
/// day starting today (from [careShiftsClock]). Tests override this
/// provider wholesale for the display + golden cases, and drive the
/// notifier + repository for the coverage-math cases.
@riverpod
Future<List<DayCoverage>> shiftWeek(Ref ref) async {
  final List<CareShift> shifts = await ref.watch(careShiftsProvider.future);
  final DateTime today = _dayStart(ref.watch(careShiftsClockProvider)());
  return <DayCoverage>[
    for (int i = 0; i < 7; i++)
      coverageFor(shifts, today.add(Duration(days: i))),
  ];
}

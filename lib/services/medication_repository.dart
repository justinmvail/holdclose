import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/medication.dart';

part 'medication_repository.g.dart';

/// One concrete dose occurrence — a `(Medication, DoseSchedule,
/// scheduledFor)` triple, optionally paired with the [DoseLog] row that
/// records whether the caregiver gave it (TASKS.md Phase 12.2).
///
/// [MedicationRepository.upcomingDoses] returns only un-logged
/// occurrences (`log == null`); [MedicationRepository.dosesByDay] returns
/// every occurrence on the day with its log attached so the "today's
/// doses" UI (Phase 12.4) can render status badges in the same pass.
@immutable
class ScheduledDose {
  const ScheduledDose({
    required this.medication,
    required this.schedule,
    required this.scheduledFor,
    this.log,
  });

  final Medication medication;
  final DoseSchedule schedule;
  final DateTime scheduledFor;
  final DoseLog? log;

  /// Convenience for UI code branching on "do I render a checkbox or a
  /// status badge?" — the dose-log screen (Phase 12.4) flips on this.
  bool get isLogged => log != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScheduledDose &&
          other.medication == medication &&
          other.schedule == schedule &&
          other.scheduledFor == scheduledFor &&
          other.log == log);

  @override
  int get hashCode => Object.hash(medication, schedule, scheduledFor, log);

  @override
  String toString() => 'ScheduledDose(${medication.name} @ $scheduledFor'
      '${log == null ? '' : ', logged=${log!.status.name}'})';
}

/// Persistence + computed helpers for the medication tracker (TASKS.md
/// Phase 12.2).
///
/// Wraps the three drift tables [MedicationsTable], [DoseSchedulesTable]
/// and [DoseLogsTable] behind plain CRUD plus three derived views the
/// medication-list, dose-log and doctor-visit-PDF surfaces all read:
///
///   - [upcomingDoses] expands each medication's [DoseSchedule] into
///     concrete `DateTime`s across the next [Duration], minus any
///     occurrence that already has a [DoseLog] row, so the home-screen
///     "next dose" tile never double-counts a dose the caregiver already
///     gave.
///   - [dosesByDay] expands the schedules onto one local-calendar day and
///     attaches the matching log (if any) — the data shape the "today's
///     doses" screen (Phase 12.4) lays out as a checklist.
///   - [adherenceRate] scores a medication's last-N-days history as the
///     fraction of *not-skipped* prescribed doses that were actually
///     given. Skipped logs are excluded from both numerator and
///     denominator because a deliberate hold (asleep, vomiting) is
///     medically distinct from a missed dose and shouldn't punish the
///     caregiver's score.
///
/// Each freezed model serialises through its `toJson` shape into the
/// row's `payload` column — same blob-with-lifted-keys pattern
/// [ChatRepository] / [DriftStorageProvider] use, so future model fields
/// persist without a schema bump. Deleting a [Medication] cascades to
/// its schedules + logs via the FK `ON DELETE CASCADE` declared in
/// `lib/db/tables.dart`; the `PRAGMA foreign_keys = ON` in
/// [CareblazersDatabase]'s `beforeOpen` is what makes that cascade real.
class MedicationRepository {
  MedicationRepository(this._db, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final CareblazersDatabase _db;
  final DateTime Function() _clock;

  // ─────────────────────────────────────────── Medication CRUD ──

  /// Insert-or-replace [medication] by id. The lifted [name] column
  /// keeps the alphabetical sort in [listMedications] from having to
  /// decode every payload.
  Future<void> upsertMedication(Medication medication) async {
    await _db.into(_db.medicationsTable).insertOnConflictUpdate(
          MedicationsTableCompanion.insert(
            id: medication.id,
            name: medication.name,
            payload: jsonEncode(medication.toJson()),
          ),
        );
  }

  /// Drop the medication row. The FK's `ON DELETE CASCADE` removes its
  /// schedules + logs in the same statement — verified by the
  /// `cascade-delete` test.
  ///
  /// This is the *hard* delete — it wipes the dose history with the
  /// medication. The caregiver-facing remove path goes through
  /// [softDeleteMedication] instead, which keeps the history on disk.
  Future<void> deleteMedication(String medicationId) async {
    await (_db.delete(_db.medicationsTable)
          ..where((t) => t.id.equals(medicationId)))
        .go();
  }

  /// Tombstone [medicationId] (TASKS.md Phase 15.6) — stamp its
  /// [Medication.deletedAt] with the current clock and leave the row,
  /// its schedules, and its dose history on disk.
  ///
  /// A soft-deleted medication drops out of [listMedications] (and so out
  /// of every derived view: [upcomingDoses], [dosesByDay], the
  /// medication-list screen, the home "today" card) while staying
  /// recoverable. No-op when the medication is absent or already
  /// tombstoned.
  Future<void> softDeleteMedication(String medicationId) async {
    final Medication? med = await getMedication(medicationId);
    if (med == null || med.deletedAt != null) return;
    await upsertMedication(med.copyWith(deletedAt: _clock()));
  }

  /// Every *live* medication, alphabetical by name — the order the
  /// medication-list screen (Phase 12.3) renders tiles in. Tombstoned
  /// rows (soft-deleted via [softDeleteMedication]) are filtered out so a
  /// removed medication disappears from the list and every view layered
  /// on top of it.
  Future<List<Medication>> listMedications() async {
    final List<MedicationsTableData> rows =
        await (_db.select(_db.medicationsTable)
              ..orderBy(<OrderClauseGenerator<$MedicationsTableTable>>[
                (t) => OrderingTerm(expression: t.name, mode: OrderingMode.asc),
              ]))
            .get();
    return rows
        .map((MedicationsTableData r) =>
            Medication.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .where((Medication m) => m.deletedAt == null)
        .toList();
  }

  /// One medication by id, or null if absent. The add-med-form's edit
  /// path (Phase 12.3) reads through this to hydrate the form.
  Future<Medication?> getMedication(String id) async {
    final MedicationsTableData? row = await (_db.select(_db.medicationsTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return Medication.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  // ─────────────────────────────────────────── DoseSchedule CRUD ──

  /// Insert-or-replace [schedule] by id. The add-med form (Phase 12.3)
  /// inserts a default daily-8am schedule alongside each new
  /// medication; the schedule-edit screen overwrites it.
  Future<void> upsertSchedule(DoseSchedule schedule) async {
    await _db.into(_db.doseSchedulesTable).insertOnConflictUpdate(
          DoseSchedulesTableCompanion.insert(
            id: schedule.id,
            medicationId: schedule.medicationId,
            payload: jsonEncode(schedule.toJson()),
          ),
        );
  }

  /// Drop the schedule row. The medication is untouched and other
  /// schedules on the same medication keep firing.
  Future<void> deleteSchedule(String scheduleId) async {
    await (_db.delete(_db.doseSchedulesTable)
          ..where((t) => t.id.equals(scheduleId)))
        .go();
  }

  /// Every schedule attached to [medicationId], in insertion order. A
  /// medication can carry multiple schedules — see [DoseSchedule]'s
  /// docstring for the "two strengths same drug" example.
  Future<List<DoseSchedule>> schedulesFor(String medicationId) async {
    final List<DoseSchedulesTableData> rows =
        await (_db.select(_db.doseSchedulesTable)
              ..where((t) => t.medicationId.equals(medicationId)))
            .get();
    return rows
        .map((DoseSchedulesTableData r) => DoseSchedule.fromJson(
            jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  // ─────────────────────────────────────────── DoseLog CRUD ──

  /// Insert-or-replace [log] by id. The dose-log screen (Phase 12.4)
  /// hits this when the caregiver checks a dose off; the repository
  /// never mints log rows by itself in v1 — every row is caregiver-
  /// initiated. (A later phase may materialise "missed" rows
  /// automatically; today they exist implicitly as "scheduled but no
  /// log" in [adherenceRate]'s arithmetic.)
  Future<void> upsertDoseLog(DoseLog log) async {
    await _db.into(_db.doseLogsTable).insertOnConflictUpdate(
          DoseLogsTableCompanion.insert(
            id: log.id,
            medicationId: log.medicationId,
            scheduledForMs: log.scheduledFor.millisecondsSinceEpoch,
            payload: jsonEncode(log.toJson()),
          ),
        );
  }

  /// Drop the dose-log row. Undo path for a caregiver mistap on the
  /// dose-log screen.
  Future<void> deleteDoseLog(String logId) async {
    await (_db.delete(_db.doseLogsTable)..where((t) => t.id.equals(logId)))
        .go();
  }

  /// Every log row for [medicationId], chronological by scheduled
  /// time. The lifted [DoseLogsTable.scheduledForMs] column means this
  /// query doesn't decode payloads to sort.
  Future<List<DoseLog>> logsFor(String medicationId) async {
    final List<DoseLogsTableData> rows = await (_db.select(_db.doseLogsTable)
          ..where((t) => t.medicationId.equals(medicationId))
          ..orderBy(<OrderClauseGenerator<$DoseLogsTableTable>>[
            (t) => OrderingTerm(
                expression: t.scheduledForMs, mode: OrderingMode.asc),
          ]))
        .get();
    return rows
        .map((DoseLogsTableData r) =>
            DoseLog.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  // ─────────────────────────────────────────── Computed helpers ──

  /// Scheduled doses across `[now, now + within]` that don't yet have
  /// a matching [DoseLog] row — what the home-screen "next dose" tile
  /// and the medication-list "next" subtitle pull from.
  ///
  /// A dose's "match" is millisecond-equal on `scheduledFor`, so a
  /// log row written from the dose-log screen (which echoes the same
  /// expanded `DateTime` back) is excluded on the next read. Sorted
  /// ascending by [ScheduledDose.scheduledFor].
  Future<List<ScheduledDose>> upcomingDoses({
    Duration within = const Duration(days: 7),
  }) async {
    final DateTime now = _clock();
    final DateTime to = now.add(within);
    final List<Medication> meds = await listMedications();
    final List<ScheduledDose> out = <ScheduledDose>[];
    for (final Medication med in meds) {
      final List<DoseSchedule> schedules = await schedulesFor(med.id);
      final List<DoseLog> logs = await logsFor(med.id);
      final Set<int> loggedMs = <int>{
        for (final DoseLog l in logs) l.scheduledFor.millisecondsSinceEpoch,
      };
      for (final DoseSchedule sched in schedules) {
        for (final DateTime occurrence in _expandSchedule(sched, now, to)) {
          if (loggedMs.contains(occurrence.millisecondsSinceEpoch)) continue;
          out.add(ScheduledDose(
            medication: med,
            schedule: sched,
            scheduledFor: occurrence,
          ));
        }
      }
    }
    out.sort((ScheduledDose a, ScheduledDose b) =>
        a.scheduledFor.compareTo(b.scheduledFor));
    return List<ScheduledDose>.unmodifiable(out);
  }

  /// Every scheduled dose that falls on the local-calendar day of
  /// [date] — `[startOfDay, endOfDay]` — with the matching [DoseLog]
  /// attached if one exists. The "today's doses" screen (Phase 12.4)
  /// renders the result as a chronological checklist.
  Future<List<ScheduledDose>> dosesByDay(DateTime date) async {
    final DateTime startOfDay = DateTime(date.year, date.month, date.day);
    final DateTime endOfDay =
        DateTime(date.year, date.month, date.day, 23, 59, 59, 999);
    final List<Medication> meds = await listMedications();
    final List<ScheduledDose> out = <ScheduledDose>[];
    for (final Medication med in meds) {
      final List<DoseSchedule> schedules = await schedulesFor(med.id);
      final List<DoseLog> logs = await logsFor(med.id);
      final Map<int, DoseLog> logsByMs = <int, DoseLog>{
        for (final DoseLog l in logs) l.scheduledFor.millisecondsSinceEpoch: l,
      };
      for (final DoseSchedule sched in schedules) {
        for (final DateTime occurrence
            in _expandSchedule(sched, startOfDay, endOfDay)) {
          out.add(ScheduledDose(
            medication: med,
            schedule: sched,
            scheduledFor: occurrence,
            log: logsByMs[occurrence.millisecondsSinceEpoch],
          ));
        }
      }
    }
    out.sort((ScheduledDose a, ScheduledDose b) =>
        a.scheduledFor.compareTo(b.scheduledFor));
    return List<ScheduledDose>.unmodifiable(out);
  }

  /// Fraction in `[0.0, 1.0]` of [forMedication]'s prescribed doses in
  /// the trailing [window] that were actually given.
  ///
  /// Numerator = logs with [DoseStatus.taken] or [DoseStatus.late].
  /// Denominator = numerator + missed, where "missed" is a logged
  /// [DoseStatus.missed] OR an expanded scheduled occurrence with no
  /// log row at all. [DoseStatus.skipped] is excluded from both —
  /// deliberate holds shouldn't count against the caregiver per
  /// [DoseStatus.skipped]'s docstring.
  ///
  /// Returns `1.0` when the window has zero scoreable doses (a brand-
  /// new medication, or one with only skipped logs) so the UI can
  /// render "—" without a special-case branch.
  Future<double> adherenceRate({
    required String forMedication,
    required Duration window,
  }) async {
    final DateTime now = _clock();
    final DateTime from = now.subtract(window);
    final List<DoseSchedule> schedules = await schedulesFor(forMedication);
    final List<DoseLog> logs = await logsFor(forMedication);
    final Map<int, DoseLog> logsByMs = <int, DoseLog>{
      for (final DoseLog l in logs) l.scheduledFor.millisecondsSinceEpoch: l,
    };

    int taken = 0;
    int missed = 0;
    for (final DoseSchedule sched in schedules) {
      for (final DateTime occurrence in _expandSchedule(sched, from, now)) {
        final DoseLog? log = logsByMs[occurrence.millisecondsSinceEpoch];
        if (log == null) {
          missed++;
          continue;
        }
        switch (log.status) {
          case DoseStatus.taken:
          case DoseStatus.late:
            taken++;
          case DoseStatus.missed:
            missed++;
          case DoseStatus.skipped:
            break;
        }
      }
    }
    final int scoreable = taken + missed;
    if (scoreable == 0) return 1.0;
    return taken / scoreable;
  }

  /// Walks every scheduled occurrence of [schedule] in `[from, to]`
  /// inclusive (`asNeeded` schedules yield nothing). Clamps the walk
  /// to `schedule.startsOn` / `schedule.endsOn` so a paused or
  /// not-yet-started schedule contributes no occurrences.
  ///
  /// Steps the calendar via `DateTime(y, m, d + 1)` rather than
  /// `Duration(days: 1)` arithmetic — adding 24h on a DST transition
  /// day lands on 23h or 25h ahead and would silently drop or
  /// duplicate that day's doses. Constructing the next-day midnight
  /// directly lets Dart's wall-clock semantics resolve the transition.
  Iterable<DateTime> _expandSchedule(
    DoseSchedule schedule,
    DateTime from,
    DateTime to,
  ) sync* {
    if (schedule.frequencyKind == FrequencyKind.asNeeded) return;
    if (schedule.timesOfDay.isEmpty) return;

    final DateTime windowStart =
        from.isBefore(schedule.startsOn) ? schedule.startsOn : from;
    final DateTime? endsOn = schedule.endsOn;
    final DateTime windowEnd =
        endsOn != null && endsOn.isBefore(to) ? endsOn : to;
    if (windowEnd.isBefore(windowStart)) return;

    DateTime day =
        DateTime(windowStart.year, windowStart.month, windowStart.day);
    final DateTime lastDay =
        DateTime(windowEnd.year, windowEnd.month, windowEnd.day);
    while (!day.isAfter(lastDay)) {
      if (schedule.frequencyKind == FrequencyKind.weekly &&
          !schedule.daysOfWeek.contains(day.weekday)) {
        day = DateTime(day.year, day.month, day.day + 1);
        continue;
      }
      for (final TimeOfDay tod in schedule.timesOfDay) {
        final DateTime occurrence =
            DateTime(day.year, day.month, day.day, tod.hour, tod.minute);
        if (occurrence.isBefore(windowStart)) continue;
        if (occurrence.isAfter(windowEnd)) continue;
        yield occurrence;
      }
      day = DateTime(day.year, day.month, day.day + 1);
    }
  }
}

/// Riverpod-wired singleton (TASKS.md Phase 12.2). The medication
/// screens (Phase 12.3 + 12.4) and the doctor-visit PDF exporter (Phase
/// 12.8) reach for [medicationRepositoryProvider] and never see the
/// concrete drift database — same indirection [chatRepositoryProvider]
/// and [seedRepositoryProvider] use.
///
/// In production the repo opens its own [CareblazersDatabase] handle
/// onto the same SQLite file the rest of the app shares; SQLite's
/// per-connection serialization keeps that safe. Tests build a
/// [MedicationRepository] directly against `CareblazersDatabase(
/// NativeDatabase.memory())` so each test gets an isolated DB.
///
/// Named `medicationRepositoryBackend` so the generated class is
/// [MedicationRepositoryBackendProvider], leaving room for the
/// natural-language [medicationRepositoryProvider] alias below.
@Riverpod(keepAlive: true)
MedicationRepository medicationRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return MedicationRepository(db);
}

/// Alias for consumers — matches the `medicationRepositoryProvider`
/// name the medication screens and PDF exporter reach for.
final MedicationRepositoryBackendProvider medicationRepositoryProvider =
    medicationRepositoryBackendProvider;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/medication.dart';

part 'medication_repository.g.dart';

/// One concrete dose occurrence — a `(Medication, DoseWindow,
/// MedicationWindowEntry, scheduledFor)` quad, optionally paired with
/// the [DoseLog] row that records whether the caregiver gave it.
///
/// [MedicationRepository.upcomingDoses] returns only un-logged
/// occurrences (`log == null`); [MedicationRepository.dosesByDay]
/// returns every occurrence on the day with its log attached so the
/// "today's doses" UI can render status badges in the same pass.
@immutable
class ScheduledDose {
  const ScheduledDose({
    required this.medication,
    required this.window,
    required this.entry,
    required this.scheduledFor,
    this.log,
  });

  final Medication medication;
  final DoseWindow window;
  final MedicationWindowEntry entry;
  final DateTime scheduledFor;
  final DoseLog? log;

  /// Convenience for UI code branching on "do I render a checkbox or a
  /// status badge?" — the dose-log screen flips on this.
  bool get isLogged => log != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScheduledDose &&
          other.medication == medication &&
          other.window == window &&
          other.entry == entry &&
          other.scheduledFor == scheduledFor &&
          other.log == log);

  @override
  int get hashCode =>
      Object.hash(medication, window, entry, scheduledFor, log);

  @override
  String toString() => 'ScheduledDose(${medication.name} '
      '@ ${window.label} $scheduledFor'
      '${log == null ? '' : ', logged=${log!.status.name}'})';
}

/// Persistence + computed helpers for the medication tracker.
///
/// Wraps four drift tables — [MedicationsTable], [DoseWindowsTable],
/// [MedicationWindowEntriesTable], [DoseLogsTable] — behind plain CRUD
/// plus three derived views the medication-list, dose-log, schedule
/// card, and doctor-visit-PDF surfaces all read:
///
///   - [upcomingDoses] expands every window × entry into concrete
///     `DateTime`s across the next [Duration], minus any occurrence
///     that already has a [DoseLog] row.
///   - [dosesByDay] expands the window × entry pairs onto one
///     local-calendar day with the matching log attached — the data
///     shape the "today's doses" screen lays out as a checklist.
///   - [dosesInWindow] is the multi-day variant powering the Home
///     Schedule card and the Care Calendar.
///   - [adherenceRate] scores a medication's last-N-days history as
///     the fraction of *not-skipped* prescribed doses that were
///     actually given.
///
/// Each freezed model serialises through its `toJson` shape into the
/// row's `payload` column — same blob-with-lifted-keys pattern the
/// other repositories use. Deleting a [Medication] cascades to its
/// window entries + logs via the FK `ON DELETE CASCADE` declared in
/// `lib/db/tables.dart`. Deleting a [DoseWindow] cascades to its
/// entries (so a "delete this window" action doesn't strand orphans).
class MedicationRepository {
  MedicationRepository(this._db, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final CareblazersDatabase _db;
  final DateTime Function() _clock;

  // ─────────────────────────────────────────── Medication CRUD ──

  /// Insert-or-replace [medication] by id.
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
  /// entries + logs in the same statement.
  Future<void> deleteMedication(String medicationId) async {
    await (_db.delete(_db.medicationsTable)
          ..where((t) => t.id.equals(medicationId)))
        .go();
  }

  /// Tombstone [medicationId] — stamp its [Medication.deletedAt] with
  /// the current clock and leave the row, its window entries, and its
  /// dose history on disk. A soft-deleted med drops out of every
  /// derived view while staying recoverable.
  Future<void> softDeleteMedication(String medicationId) async {
    final Medication? med = await getMedication(medicationId);
    if (med == null || med.deletedAt != null) return;
    await upsertMedication(med.copyWith(deletedAt: _clock()));
  }

  /// Every *live* medication, alphabetical by name. Filters out both
  /// soft-deleted rows (`deletedAt != null`) and medications whose
  /// optional [Medication.endsAt] has passed — caregivers asked for
  /// short-course meds (antibiotics, taper plans) to disappear on
  /// their own once the prescription runs out.
  Future<List<Medication>> listMedications() async {
    final DateTime now = _clock();
    final List<MedicationsTableData> rows =
        await (_db.select(_db.medicationsTable)
              ..orderBy(<OrderClauseGenerator<$MedicationsTableTable>>[
                (t) =>
                    OrderingTerm(expression: t.name, mode: OrderingMode.asc),
              ]))
            .get();
    return rows
        .map((MedicationsTableData r) =>
            Medication.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .where((Medication m) =>
            m.deletedAt == null &&
            (m.endsAt == null || m.endsAt!.isAfter(now)))
        .toList();
  }

  /// One medication by id, or null if absent.
  Future<Medication?> getMedication(String id) async {
    final MedicationsTableData? row = await (_db.select(_db.medicationsTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return Medication.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  // ─────────────────────────────────────────── DoseWindow CRUD ──

  /// Insert-or-replace [window] by id. The lifted `anchorMinute` keeps
  /// the windows-list screen's sort cheap; `-1` is the sentinel for
  /// "as needed".
  Future<void> upsertWindow(DoseWindow window) async {
    final int anchor = window.anchorTime == null
        ? -1
        : (window.anchorTime!.hour * 60 + window.anchorTime!.minute);
    await _db.into(_db.doseWindowsTable).insertOnConflictUpdate(
          DoseWindowsTableCompanion.insert(
            id: window.id,
            patientId: window.patientId,
            anchorMinute: anchor,
            payload: jsonEncode(window.toJson()),
          ),
        );
  }

  /// Drop the window. FK cascade removes its entries; orphan logs (if
  /// any) stay so the dose history survives a window rename / regroup.
  Future<void> deleteWindow(String windowId) async {
    await (_db.delete(_db.doseWindowsTable)
          ..where((t) => t.id.equals(windowId)))
        .go();
  }

  /// Every window for [patientId], ordered by sort then by anchor
  /// minute (as-needed = -1 lands first by minute, last by sort).
  Future<List<DoseWindow>> windowsForPatient(String patientId) async {
    final List<DoseWindowsTableData> rows =
        await (_db.select(_db.doseWindowsTable)
              ..where((t) => t.patientId.equals(patientId)))
            .get();
    final List<DoseWindow> windows = <DoseWindow>[
      for (final DoseWindowsTableData r in rows)
        DoseWindow.fromJson(jsonDecode(r.payload) as Map<String, dynamic>),
    ];
    windows.sort((DoseWindow a, DoseWindow b) {
      if (a.sortOrder != b.sortOrder) {
        return a.sortOrder.compareTo(b.sortOrder);
      }
      final int? aMin =
          a.anchorTime == null ? null : a.anchorTime!.hour * 60 + a.anchorTime!.minute;
      final int? bMin =
          b.anchorTime == null ? null : b.anchorTime!.hour * 60 + b.anchorTime!.minute;
      if (aMin == null && bMin == null) return a.id.compareTo(b.id);
      if (aMin == null) return 1;
      if (bMin == null) return -1;
      return aMin.compareTo(bMin);
    });
    return windows;
  }

  /// One window by id, or null if absent.
  Future<DoseWindow?> getWindow(String id) async {
    final DoseWindowsTableData? row =
        await (_db.select(_db.doseWindowsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    if (row == null) return null;
    return DoseWindow.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  // ─────────────────────────────────────────── Entry CRUD ──

  /// Insert-or-replace a (medication, window) entry.
  Future<void> upsertEntry(MedicationWindowEntry entry) async {
    await _db.into(_db.medicationWindowEntriesTable).insertOnConflictUpdate(
          MedicationWindowEntriesTableCompanion.insert(
            id: entry.id,
            medicationId: entry.medicationId,
            windowId: entry.windowId,
            payload: jsonEncode(entry.toJson()),
          ),
        );
  }

  /// Drop a single entry by id. Used when the caregiver removes a med
  /// from a window without deleting the medication itself.
  Future<void> deleteEntry(String entryId) async {
    await (_db.delete(_db.medicationWindowEntriesTable)
          ..where((t) => t.id.equals(entryId)))
        .go();
  }

  /// Every entry attached to [windowId], in insertion order.
  Future<List<MedicationWindowEntry>> entriesForWindow(String windowId) async {
    final List<MedicationWindowEntriesTableData> rows =
        await (_db.select(_db.medicationWindowEntriesTable)
              ..where((t) => t.windowId.equals(windowId)))
            .get();
    return <MedicationWindowEntry>[
      for (final MedicationWindowEntriesTableData r in rows)
        MedicationWindowEntry.fromJson(
            jsonDecode(r.payload) as Map<String, dynamic>),
    ];
  }

  /// Every entry attached to [medicationId] across all windows. The
  /// medication-detail / edit screen reads this to show "Taken at:
  /// Morning, Bedtime" and to let the caregiver toggle entries.
  Future<List<MedicationWindowEntry>> entriesForMedication(
      String medicationId) async {
    final List<MedicationWindowEntriesTableData> rows =
        await (_db.select(_db.medicationWindowEntriesTable)
              ..where((t) => t.medicationId.equals(medicationId)))
            .get();
    return <MedicationWindowEntry>[
      for (final MedicationWindowEntriesTableData r in rows)
        MedicationWindowEntry.fromJson(
            jsonDecode(r.payload) as Map<String, dynamic>),
    ];
  }

  // ─────────────────────────────────────────── DoseLog CRUD ──

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

  Future<void> deleteDoseLog(String logId) async {
    await (_db.delete(_db.doseLogsTable)..where((t) => t.id.equals(logId)))
        .go();
  }

  /// Every log row for [medicationId], chronological by scheduled time.
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

  /// Scheduled doses across `[now, now + within]` that don't yet have a
  /// matching [DoseLog] row.
  Future<List<ScheduledDose>> upcomingDoses({
    Duration within = const Duration(days: 7),
    String patientId = 'demo-patient-mary',
  }) async {
    final DateTime now = _clock();
    final DateTime to = now.add(within);
    final List<ScheduledDose> all =
        await _expandAcross(from: now, to: to, patientId: patientId);
    return List<ScheduledDose>.unmodifiable(
        all.where((ScheduledDose d) => d.log == null));
  }

  /// Every scheduled dose between [from] and [to] (inclusive) with the
  /// matching [DoseLog] attached when one exists.
  Future<List<ScheduledDose>> dosesInWindow(
    DateTime from,
    DateTime to, {
    String patientId = 'demo-patient-mary',
  }) async {
    return List<ScheduledDose>.unmodifiable(
        await _expandAcross(from: from, to: to, patientId: patientId));
  }

  /// Every scheduled dose that falls on the local-calendar day of
  /// [date] with the matching [DoseLog] attached.
  Future<List<ScheduledDose>> dosesByDay(
    DateTime date, {
    String patientId = 'demo-patient-mary',
  }) async {
    final DateTime startOfDay = DateTime(date.year, date.month, date.day);
    final DateTime endOfDay =
        DateTime(date.year, date.month, date.day, 23, 59, 59, 999);
    return List<ScheduledDose>.unmodifiable(await _expandAcross(
        from: startOfDay, to: endOfDay, patientId: patientId));
  }

  /// Fraction in `[0.0, 1.0]` of [forMedication]'s prescribed doses in
  /// the trailing [window] that were actually given.
  ///
  /// Numerator = logs with [DoseStatus.taken] or [DoseStatus.late].
  /// Denominator = numerator + missed, where "missed" is a logged
  /// [DoseStatus.missed] OR an expanded scheduled occurrence with no
  /// log row at all. [DoseStatus.skipped] is excluded from both —
  /// deliberate holds shouldn't count against the caregiver.
  ///
  /// Returns `1.0` when the window has zero scoreable doses so the UI
  /// can render "—" without a special-case branch.
  Future<double> adherenceRate({
    required String forMedication,
    required Duration window,
    String patientId = 'demo-patient-mary',
  }) async {
    final DateTime now = _clock();
    final DateTime from = now.subtract(window);
    final List<DoseLog> logs = await logsFor(forMedication);
    final Map<int, DoseLog> logsByMs = <int, DoseLog>{
      for (final DoseLog l in logs) l.scheduledFor.millisecondsSinceEpoch: l,
    };

    int taken = 0;
    int missed = 0;
    // Filter the full expansion down to this medication's occurrences.
    final List<ScheduledDose> all =
        await _expandAcross(from: from, to: now, patientId: patientId);
    for (final ScheduledDose dose in all) {
      if (dose.medication.id != forMedication) continue;
      final DoseLog? log = logsByMs[dose.scheduledFor.millisecondsSinceEpoch];
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
    final int scoreable = taken + missed;
    if (scoreable == 0) return 1.0;
    return taken / scoreable;
  }

  // ─────────────────────────────────────────── Expansion ──

  /// Core expansion — walk every window for [patientId], every entry in
  /// each window, and emit one [ScheduledDose] per occurrence in
  /// `[from, to]`. Attaches the matching [DoseLog] when one exists.
  /// Sorted via [_compareScheduledDose] for stable ordering.
  Future<List<ScheduledDose>> _expandAcross({
    required DateTime from,
    required DateTime to,
    required String patientId,
  }) async {
    final List<Medication> meds = await listMedications();
    final Map<String, Medication> medsById = <String, Medication>{
      for (final Medication m in meds) m.id: m,
    };
    final List<DoseWindow> windows = await windowsForPatient(patientId);
    final List<ScheduledDose> out = <ScheduledDose>[];
    for (final DoseWindow window in windows) {
      if (window.isAsNeeded) continue;
      final List<MedicationWindowEntry> entries =
          await entriesForWindow(window.id);
      for (final MedicationWindowEntry entry in entries) {
        final Medication? med = medsById[entry.medicationId];
        if (med == null) continue; // soft-deleted or wiped
        final List<DoseLog> logs = await logsFor(med.id);
        final Map<int, DoseLog> logsByMs = <int, DoseLog>{
          for (final DoseLog l in logs)
            l.scheduledFor.millisecondsSinceEpoch: l,
        };
        // Clamp the upper bound of the expansion at the medication's
        // [Medication.endsAt] so a future-ending med doesn't project
        // ghost doses past the day the caregiver expects it to stop.
        final DateTime? medEnd = med.endsAt;
        final DateTime clampedTo =
            (medEnd != null && medEnd.isBefore(to)) ? medEnd : to;
        if (clampedTo.isBefore(from)) continue;
        for (final DateTime occurrence
            in _expandEntry(window, entry, from, clampedTo)) {
          out.add(ScheduledDose(
            medication: med,
            window: window,
            entry: entry,
            scheduledFor: occurrence,
            log: logsByMs[occurrence.millisecondsSinceEpoch],
          ));
        }
      }
    }
    out.sort(_compareScheduledDose);
    return out;
  }

  /// Deterministic ordering. Primary by `scheduledFor` ascending; ties
  /// break by med name (case-insensitive) → med id → window id → entry
  /// id so same-time doses keep a stable order across rebuilds.
  static int _compareScheduledDose(ScheduledDose a, ScheduledDose b) {
    final int byTime = a.scheduledFor.compareTo(b.scheduledFor);
    if (byTime != 0) return byTime;
    final int byName = a.medication.name
        .toLowerCase()
        .compareTo(b.medication.name.toLowerCase());
    if (byName != 0) return byName;
    final int byMedId = a.medication.id.compareTo(b.medication.id);
    if (byMedId != 0) return byMedId;
    final int byWindow = a.window.id.compareTo(b.window.id);
    if (byWindow != 0) return byWindow;
    return a.entry.id.compareTo(b.entry.id);
  }

  /// Walk every occurrence of [entry] inside [window] in `[from, to]`.
  /// Steps the calendar via `DateTime(y, m, d + 1)` rather than
  /// `Duration(days: 1)` so a DST transition day doesn't drop or
  /// duplicate doses.
  Iterable<DateTime> _expandEntry(
    DoseWindow window,
    MedicationWindowEntry entry,
    DateTime from,
    DateTime to,
  ) sync* {
    final TimeOfDay? anchor = window.anchorTime;
    if (anchor == null) return; // as-needed
    final DateTime windowStart =
        from.isBefore(entry.startsOn) ? entry.startsOn : from;
    final DateTime? endsOn = entry.endsOn;
    final DateTime windowEnd =
        endsOn != null && endsOn.isBefore(to) ? endsOn : to;
    if (windowEnd.isBefore(windowStart)) return;

    DateTime day =
        DateTime(windowStart.year, windowStart.month, windowStart.day);
    final DateTime lastDay =
        DateTime(windowEnd.year, windowEnd.month, windowEnd.day);
    while (!day.isAfter(lastDay)) {
      // daysOfWeek empty → fire every day. Otherwise only the listed
      // weekdays (DateTime.weekday: Mon=1..Sun=7).
      if (entry.daysOfWeek.isNotEmpty &&
          !entry.daysOfWeek.contains(day.weekday)) {
        day = DateTime(day.year, day.month, day.day + 1);
        continue;
      }
      final DateTime occurrence =
          DateTime(day.year, day.month, day.day, anchor.hour, anchor.minute);
      if (!occurrence.isBefore(windowStart) &&
          !occurrence.isAfter(windowEnd)) {
        yield occurrence;
      }
      day = DateTime(day.year, day.month, day.day + 1);
    }
  }
}

/// Riverpod-wired singleton.
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

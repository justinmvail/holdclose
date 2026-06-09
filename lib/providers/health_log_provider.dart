import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/health_log_entry.dart';
import '../services/sync_sink.dart';

part 'health_log_provider.g.dart';

/// Persistence for the health log (TASKS.md Phase 14.16).
///
/// Wraps the single drift table [HealthLogEntriesTable] behind plain
/// CRUD plus a [byPatient] query. Each [HealthLogEntry] serialises
/// through its `toJson` shape into the row's `payload` column — same
/// blob-with-lifted-keys pattern [AppointmentRepository] /
/// [MedicationRepository] use; the lifted [HealthLogEntriesTable
/// .recordedAtMs] column keeps [listAll] / [byPatient] ordering off the
/// blob, and [HealthLogEntriesTable.patientId] keeps the [byPatient]
/// filter off it too.
///
/// There's no provider/FK cascade to worry about — the health-log table
/// stands alone (see `lib/db/tables.dart` for why the [patientId] link
/// is logical, not a DB foreign key).
class HealthLogRepository with SyncSinkHost {
  HealthLogRepository(this._db);

  final CareblazersDatabase _db;

  /// Close the underlying database. The riverpod provider wires this to
  /// `ref.onDispose`.
  Future<void> close() => _db.close();

  /// Insert-or-replace [entry] by id. The lifted columns are kept in
  /// sync with the blob so the recency + by-patient reads never parse a
  /// payload to filter or order.
  Future<void> upsert(HealthLogEntry entry) async {
    await _db.into(_db.healthLogEntriesTable).insertOnConflictUpdate(
          HealthLogEntriesTableCompanion.insert(
            id: entry.id,
            patientId: entry.patientId,
            recordedAtMs: entry.recordedAt.millisecondsSinceEpoch,
            payload: jsonEncode(entry.toJson()),
          ),
        );
    emitUpsert('health_log_entries', entry.id, entry.toJson());
  }

  /// Drop the row with this id. No-op if absent.
  Future<void> delete(String id) async {
    await (_db.delete(_db.healthLogEntriesTable)
          ..where((t) => t.id.equals(id)))
        .go();
    emitDelete('health_log_entries', id);
  }

  /// One entry by id, or null if absent.
  Future<HealthLogEntry?> getById(String id) async {
    final HealthLogEntriesTableData? row =
        await (_db.select(_db.healthLogEntriesTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    if (row == null) return null;
    return _decode(row.payload);
  }

  /// Every entry, newest first.
  Future<List<HealthLogEntry>> listAll() async {
    final List<HealthLogEntriesTableData> rows =
        await (_db.select(_db.healthLogEntriesTable)
              ..orderBy(<OrderClauseGenerator<$HealthLogEntriesTableTable>>[
                (t) => OrderingTerm(
                    expression: t.recordedAtMs, mode: OrderingMode.desc),
              ]))
            .get();
    return rows.map((HealthLogEntriesTableData r) => _decode(r.payload)).toList();
  }

  /// Every entry for [patientId], newest first.
  Future<List<HealthLogEntry>> byPatient(String patientId) async {
    final List<HealthLogEntriesTableData> rows =
        await (_db.select(_db.healthLogEntriesTable)
              ..where((t) => t.patientId.equals(patientId))
              ..orderBy(<OrderClauseGenerator<$HealthLogEntriesTableTable>>[
                (t) => OrderingTerm(
                    expression: t.recordedAtMs, mode: OrderingMode.desc),
              ]))
            .get();
    return rows.map((HealthLogEntriesTableData r) => _decode(r.payload)).toList();
  }

  HealthLogEntry _decode(String payload) =>
      HealthLogEntry.fromJson(jsonDecode(payload) as Map<String, dynamic>);
}

/// Riverpod-wired singleton (TASKS.md Phase 14.16). The health-log
/// screen + add form (later Phase 14 tasks) reach for
/// [healthLogRepositoryProvider] and never see the concrete drift
/// database — same indirection [appointmentRepositoryProvider] uses.
///
/// In production the repo opens its own [CareblazersDatabase] handle
/// onto the shared SQLite file; SQLite's per-connection serialization
/// keeps that safe. Tests build a [HealthLogRepository] directly against
/// `CareblazersDatabase(NativeDatabase.memory())` so each test gets an
/// isolated DB.
///
/// Named `healthLogRepositoryBackend` so the generated class is
/// [HealthLogRepositoryBackendProvider], leaving room for the
/// natural-language [healthLogRepositoryProvider] alias below.
@Riverpod(keepAlive: true)
HealthLogRepository healthLogRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return HealthLogRepository(db);
}

/// Alias for consumers — matches the `healthLogRepositoryProvider` name
/// the health-log screens reach for.
final HealthLogRepositoryBackendProvider healthLogRepositoryProvider =
    healthLogRepositoryBackendProvider;

/// Wall clock the [HealthLog] notifier uses to derive the "today"
/// bucket in [HealthLog.todayByKind] (TASKS.md Phase 14.16). Overridable
/// so tests pin a fixed time and the local-midnight bucketing stays
/// deterministic regardless of the test host's local time.
@Riverpod(keepAlive: true)
DateTime Function() healthLogClock(Ref ref) => DateTime.now;

/// The loved one's health log (TASKS.md Phase 14.16).
///
/// `build()` loads every entry newest-first; [add] / [update] / [delete]
/// mutate through [healthLogRepositoryProvider] and re-read the list so
/// the screen reflects the write without a manual invalidate. The two
/// read selectors — [byPatient] and [todayByKind] — filter the already-
/// loaded state synchronously so a `ConsumerWidget` can call them in
/// `build` without awaiting.
///
/// `keepAlive: true` so a quick add from the floating "+" action and a
/// later read from the Home "Today" surfaces share one cached list.
@Riverpod(keepAlive: true)
class HealthLog extends _$HealthLog {
  @override
  Future<List<HealthLogEntry>> build() async {
    final HealthLogRepository repo = ref.watch(healthLogRepositoryProvider);
    return repo.listAll();
  }

  /// Persist a new entry, then refresh the cached list.
  Future<void> add(HealthLogEntry entry) =>
      _mutate((HealthLogRepository repo) => repo.upsert(entry));

  /// Persist an edit to an existing entry (upsert by id), then refresh.
  ///
  /// Named `updateEntry` rather than `update` because Riverpod's
  /// `AsyncNotifier` already defines an `update(...)` method with an
  /// incompatible signature — overriding it isn't allowed.
  Future<void> updateEntry(HealthLogEntry entry) =>
      _mutate((HealthLogRepository repo) => repo.upsert(entry));

  /// Delete the entry with this id, then refresh.
  Future<void> delete(String id) =>
      _mutate((HealthLogRepository repo) => repo.delete(id));

  /// Run [op] against the repo, then reload the list into [state]. The
  /// current data stays visible until the reload lands (no transient
  /// loading flash); a throw from [op] surfaces as [AsyncValue.error].
  Future<void> _mutate(
    Future<void> Function(HealthLogRepository repo) op,
  ) async {
    final HealthLogRepository repo = ref.read(healthLogRepositoryProvider);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return repo.listAll();
    });
  }

  /// Entries belonging to [patientId], newest first (the loaded list is
  /// already ordered). Empty while the first load is still in flight.
  List<HealthLogEntry> byPatient(String patientId) =>
      (state.asData?.value ?? const <HealthLogEntry>[])
          .where((HealthLogEntry e) => e.patientId == patientId)
          .toList();

  /// Entries of [kind] recorded on the current local calendar day. The
  /// "today" window is computed against the local wall clock from
  /// [healthLogClockProvider] and bucketed by local Y/M/D, so an entry
  /// at 11:59 PM and one at 12:01 AM the next morning land in different
  /// days regardless of the host's timezone.
  List<HealthLogEntry> todayByKind(HealthLogKind kind) {
    final DateTime now = ref.read(healthLogClockProvider)();
    return (state.asData?.value ?? const <HealthLogEntry>[])
        .where((HealthLogEntry e) =>
            e.kind == kind && _isSameLocalDay(e.recordedAt, now))
        .toList();
  }
}

/// True when [a] and [b] fall on the same local calendar day. Both are
/// normalised to local time first so the comparison survives entries
/// stored as UTC and a local-time clock.
bool _isSameLocalDay(DateTime a, DateTime b) {
  final DateTime la = a.toLocal();
  final DateTime lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}

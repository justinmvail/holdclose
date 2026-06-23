import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../db/tables.dart';
import '../models/journal_entry.dart';
import '../models/patient.dart';
import '../models/settings.dart';
import '../services/sync_sink.dart';

part 'storage_provider.g.dart';

/// Local persistence (BUILD_SPEC.md §6.2). Backs the journal
/// auto-log, the single-patient crisis card row, and the [AppSettings]
/// blob.
///
/// Two v1 implementations: [DriftStorageProvider] (real SQLite via
/// drift) and [InMemoryStorageProvider] (Dart `Map`, used by widget
/// tests + the demo tour). The riverpod [storageProvider] chooses based
/// on the `USE_FAKE_STORAGE` build define.
abstract class StorageProvider {
  /// Server-authoritative-sync enqueue seam for journal writes. Set once
  /// at wiring time by the sync controller (defaults to a no-op so
  /// circle-less installs + tests stay fully local). Both concrete impls
  /// satisfy this via the [SyncSinkHost] mixin.
  abstract SyncSink syncSink;

  /// Run [action] with [syncSink] suppressed — the apply dispatcher uses
  /// this so applying a *pulled* journal doc doesn't re-enqueue it (the
  /// echo-loop guard). Supplied by [SyncSinkHost].
  Future<T> applyingRemote<T>(Future<T> Function() action);

  /// Stream entries created within [window] of "now", newest first.
  /// Re-emits whenever the underlying store changes.
  Stream<List<JournalEntry>> watchJournalEntries({Duration window});

  /// Every journal entry on file, newest first — no time window. Backs
  /// the full-data backup (Issue #20 — `DataExporter`), which needs the
  /// whole history rather than the trailing window
  /// [watchJournalEntries] surfaces for the on-screen list. A one-shot
  /// `Future` (not a stream) so the exporter reads a snapshot without
  /// holding a subscription.
  Future<List<JournalEntry>> listAllJournalEntries();

  /// Insert [entry]. Returns the entry as written (id + createdAt are
  /// already populated by the caller — the storage layer never mints
  /// either).
  Future<JournalEntry> insertJournalEntry(JournalEntry entry);

  /// Replace the existing row identified by [entry.id]. No-op if the
  /// id isn't present (the journal-entry detail screen always writes
  /// the entry it just read).
  Future<void> updateJournalEntry(JournalEntry entry);

  /// Delete the entry with this id. No-op if absent.
  Future<void> deleteJournalEntry(String id);

  /// The configured loved one the app is currently centred on, or null
  /// if onboarding hasn't populated one yet (BUILD_SPEC.md §5.9 + §9.1).
  ///
  /// With one patient on file this returns that sole row — the
  /// single-patient v1 contract every existing caller relies on. With
  /// several on file (multi-patient, Issue #6) it returns the one whose
  /// id [getActivePatientId] resolves to; when no active id has been
  /// chosen yet it falls back to the first row so a freshly-added second
  /// patient never blanks the active-patient surfaces.
  Future<Patient?> getPatient();

  /// Every loved one on file, ordered by name (case-insensitive) so the
  /// "Loved ones" manager renders a stable list. Empty before onboarding
  /// populates one. Backs the multi-patient switcher (Issue #6); the
  /// single-patient surfaces keep reading [getPatient].
  Future<List<Patient>> listPatients();

  /// Insert-or-replace a patient row by [patient.id]. Adding a second
  /// (or third…) loved one goes through here just like the first — the
  /// table keys by id, so a new id appends rather than overwriting.
  Future<void> upsertPatient(Patient patient);

  /// The id of the loved one the app is currently centred on, or null
  /// when none has been explicitly selected yet (in which case callers
  /// fall back to the sole / first patient — see [getPatient]).
  ///
  /// Persisted, so the choice survives a relaunch. Set via
  /// [setActivePatientId] when the caregiver switches in the "Loved ones"
  /// manager or adds a new person.
  Future<String?> getActivePatientId();

  /// Persist [patientId] as the active loved one. The caller is
  /// responsible for invalidating `activePatientProvider` so the running
  /// app re-reads. Passing an id with no matching patient row is allowed
  /// (the manager always writes an id it just upserted); [getPatient]
  /// then falls back to the first row if the active id can't be resolved.
  Future<void> setActivePatientId(String patientId);

  /// The persisted settings, or [AppSettings.defaults] if the user has
  /// never opened Settings. Never returns null.
  Future<AppSettings> getSettings();

  /// Replace the singleton settings row.
  Future<void> updateSettings(AppSettings settings);

  /// Clear ALL local state. Used by the demo-mode "Reset on launch"
  /// toggle (BUILD_SPEC.md §9.3) — also a convenient hard-reset hook
  /// for tests.
  Future<void> reset();
}

/// Real impl backed by a [HoldcloseDatabase] (BUILD_SPEC.md §6.2).
///
/// Each freezed model is serialised to its `toJson` shape and parked in
/// the row's `payload` column — see `lib/db/tables.dart` for the
/// rationale. The [JournalEntriesTable] additionally lifts
/// `createdAtMs` to its own column so the windowed watch query filters
/// + orders without parsing every blob.
class DriftStorageProvider with SyncSinkHost implements StorageProvider {
  DriftStorageProvider(this._db);

  final HoldcloseDatabase _db;

  /// Close the underlying database. The riverpod provider wires this
  /// to `ref.onDispose`.
  Future<void> close() => _db.close();

  @override
  Stream<List<JournalEntry>> watchJournalEntries({
    Duration window = const Duration(days: 30),
  }) {
    final int cutoffMs =
        DateTime.now().subtract(window).millisecondsSinceEpoch;
    final query = _db.select(_db.journalEntriesTable)
      ..where((t) => t.createdAtMs.isBiggerOrEqualValue(cutoffMs))
      ..orderBy(<OrderClauseGenerator<$JournalEntriesTableTable>>[
        (t) =>
            OrderingTerm(expression: t.createdAtMs, mode: OrderingMode.desc),
      ]);
    return query.watch().map(
          (List<JournalEntriesTableData> rows) =>
              rows.map((r) => _decodeJournal(r.payload)).toList(),
        );
  }

  @override
  Future<List<JournalEntry>> listAllJournalEntries() async {
    final List<JournalEntriesTableData> rows =
        await (_db.select(_db.journalEntriesTable)
              ..orderBy(<OrderClauseGenerator<$JournalEntriesTableTable>>[
                (t) => OrderingTerm(
                    expression: t.createdAtMs, mode: OrderingMode.desc),
              ]))
            .get();
    return rows.map((r) => _decodeJournal(r.payload)).toList();
  }

  @override
  Future<JournalEntry> insertJournalEntry(JournalEntry entry) async {
    await _db.into(_db.journalEntriesTable).insertOnConflictUpdate(
          JournalEntriesTableCompanion.insert(
            id: entry.id,
            createdAtMs: entry.createdAt.millisecondsSinceEpoch,
            payload: jsonEncode(entry.toJson()),
          ),
        );
    emitUpsert('journal_entries', entry.id, entry.toJson());
    return entry;
  }

  @override
  Future<void> updateJournalEntry(JournalEntry entry) async {
    await (_db.update(_db.journalEntriesTable)
          ..where((t) => t.id.equals(entry.id)))
        .write(
      JournalEntriesTableCompanion(
        createdAtMs: Value<int>(entry.createdAt.millisecondsSinceEpoch),
        payload: Value<String>(jsonEncode(entry.toJson())),
      ),
    );
    emitUpsert('journal_entries', entry.id, entry.toJson());
  }

  @override
  Future<void> deleteJournalEntry(String id) async {
    await (_db.delete(_db.journalEntriesTable)
          ..where((t) => t.id.equals(id)))
        .go();
    emitDelete('journal_entries', id);
  }

  @override
  Future<Patient?> getPatient() async {
    final List<Patient> patients = await listPatients();
    if (patients.isEmpty) return null;
    final String? activeId = await getActivePatientId();
    if (activeId != null) {
      for (final Patient p in patients) {
        if (p.id == activeId) return p;
      }
    }
    // No active id chosen yet (the single-patient v1 path), or the stored
    // active id no longer resolves to a row — fall back to the first
    // patient so the active-patient surfaces never blank.
    return patients.first;
  }

  @override
  Future<List<Patient>> listPatients() async {
    final List<PatientsTableData> rows =
        await _db.select(_db.patientsTable).get();
    final List<Patient> patients = rows
        .map((PatientsTableData r) =>
            Patient.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList()
      ..sort((Patient a, Patient b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return patients;
  }

  @override
  Future<void> upsertPatient(Patient patient) async {
    await _db.into(_db.patientsTable).insertOnConflictUpdate(
          PatientsTableCompanion.insert(
            id: patient.id,
            payload: jsonEncode(patient.toJson()),
          ),
        );
    // Loved-one edits sync like every other collection (2026-06-11) —
    // the push path routes the 'patient' collection onto the protocol's
    // dedicated patient field. Suppressed by applyingRemote when this
    // write IS a pulled doc (the echo-loop guard).
    emitUpsert('patient', patient.id, patient.toJson());
  }

  @override
  Future<String?> getActivePatientId() async {
    final AppSettingsTableData? row = await (_db.select(_db.appSettingsTable)
          ..where((t) => t.id.equals(activePatientSettingsId)))
        .getSingleOrNull();
    return row?.payload;
  }

  @override
  Future<void> setActivePatientId(String patientId) async {
    // Stored as its own row in the generic key/payload app_settings
    // table (id = [activePatientSettingsId]) rather than inside the
    // [AppSettings] blob — keeps the active-patient pointer off the
    // settings model + its golden, and survives a settings reset the
    // same way the singleton row does.
    await _db.into(_db.appSettingsTable).insertOnConflictUpdate(
          AppSettingsTableCompanion.insert(
            id: activePatientSettingsId,
            payload: patientId,
          ),
        );
  }

  @override
  Future<AppSettings> getSettings() async {
    final AppSettingsTableData? row = await (_db.select(_db.appSettingsTable)
          ..where((t) => t.id.equals(appSettingsSingletonId)))
        .getSingleOrNull();
    if (row == null) return AppSettings.defaults();
    return AppSettings.fromJson(
        jsonDecode(row.payload) as Map<String, dynamic>);
  }

  @override
  Future<void> updateSettings(AppSettings settings) async {
    await _db.into(_db.appSettingsTable).insertOnConflictUpdate(
          AppSettingsTableCompanion.insert(
            id: appSettingsSingletonId,
            payload: jsonEncode(settings.toJson()),
          ),
        );
  }

  @override
  Future<void> reset() => _db.wipeAll();

  JournalEntry _decodeJournal(String payload) =>
      JournalEntry.fromJson(jsonDecode(payload) as Map<String, dynamic>);
}

/// Pure-Dart impl backed by maps + a broadcast change stream. Used by
/// widget tests (no SQLite ffi load) and as a safety net for the demo
/// tour when `USE_FAKE_STORAGE=true` is set.
///
/// Holds the same `JournalEntry` / `Patient` / `AppSettings` instances
/// the caller hands in — no cloning, no JSON round-trip — so equality
/// checks in tests stay simple.
class InMemoryStorageProvider with SyncSinkHost implements StorageProvider {
  InMemoryStorageProvider({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, JournalEntry> _entries = <String, JournalEntry>{};

  /// Keyed by patient id. [getPatient]'s no-active-id fallback sorts by
  /// name (via [listPatients]) so it resolves the same default-active row
  /// the Drift impl would, regardless of insertion order.
  final Map<String, Patient> _patients = <String, Patient>{};
  String? _activePatientId;
  AppSettings? _settings;
  final StreamController<void> _changes =
      StreamController<void>.broadcast();

  /// Release the change-notification stream. The riverpod provider
  /// wires this to `ref.onDispose`.
  Future<void> dispose() => _changes.close();

  @override
  Stream<List<JournalEntry>> watchJournalEntries({
    Duration window = const Duration(days: 30),
  }) {
    // Manual controller (rather than `async*` + `await for`) so the
    // subscription on `_changes` is wired up synchronously inside
    // `onListen` — `async*` would only subscribe after the first `yield`
    // completes a microtask hop, racing any `insertJournalEntry` call
    // the caller fires immediately after subscribing.
    late StreamController<List<JournalEntry>> controller;
    StreamSubscription<void>? changeSub;
    controller = StreamController<List<JournalEntry>>(
      onListen: () {
        controller.add(_snapshot(window));
        changeSub = _changes.stream.listen((_) {
          if (!controller.isClosed) controller.add(_snapshot(window));
        });
      },
      onCancel: () async {
        await changeSub?.cancel();
        changeSub = null;
      },
    );
    return controller.stream;
  }

  List<JournalEntry> _snapshot(Duration window) {
    final DateTime cutoff = _clock().subtract(window);
    final List<JournalEntry> rows = _entries.values
        .where((JournalEntry e) =>
            !e.createdAt.isBefore(cutoff))
        .toList()
      ..sort((JournalEntry a, JournalEntry b) =>
          b.createdAt.compareTo(a.createdAt));
    return rows;
  }

  @override
  Future<List<JournalEntry>> listAllJournalEntries() async {
    return _entries.values.toList()
      ..sort((JournalEntry a, JournalEntry b) =>
          b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<JournalEntry> insertJournalEntry(JournalEntry entry) async {
    _entries[entry.id] = entry;
    _notify();
    emitUpsert('journal_entries', entry.id, entry.toJson());
    return entry;
  }

  @override
  Future<void> updateJournalEntry(JournalEntry entry) async {
    if (!_entries.containsKey(entry.id)) return;
    _entries[entry.id] = entry;
    _notify();
    emitUpsert('journal_entries', entry.id, entry.toJson());
  }

  @override
  Future<void> deleteJournalEntry(String id) async {
    if (_entries.remove(id) != null) {
      _notify();
      emitDelete('journal_entries', id);
    }
  }

  @override
  Future<Patient?> getPatient() async {
    if (_patients.isEmpty) return null;
    final String? activeId = _activePatientId;
    if (activeId != null && _patients.containsKey(activeId)) {
      return _patients[activeId];
    }
    // No active id chosen (single-patient v1 path) or it no longer
    // resolves — fall back to the first patient by the same name-sorted
    // order [listPatients] (and the Drift impl's fallback) uses, so the
    // two backends resolve the same default-active row.
    return (await listPatients()).first;
  }

  @override
  Future<List<Patient>> listPatients() async {
    final List<Patient> patients = _patients.values.toList()
      ..sort((Patient a, Patient b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return patients;
  }

  @override
  Future<void> upsertPatient(Patient patient) async {
    _patients[patient.id] = patient;
    // Mirrors DriftStorageProvider: loved-one edits flow to the circle.
    emitUpsert('patient', patient.id, patient.toJson());
  }

  @override
  Future<String?> getActivePatientId() async => _activePatientId;

  @override
  Future<void> setActivePatientId(String patientId) async {
    _activePatientId = patientId;
  }

  @override
  Future<AppSettings> getSettings() async =>
      _settings ?? AppSettings.defaults();

  @override
  Future<void> updateSettings(AppSettings settings) async {
    _settings = settings;
  }

  @override
  Future<void> reset() async {
    _entries.clear();
    _patients.clear();
    _activePatientId = null;
    _settings = null;
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}

/// Build-time flag (BUILD_SPEC.md §6.2 — `USE_FAKE_STORAGE`).
///
/// Defaults to false so production + the simulator run against the real
/// Drift database. Set `--dart-define=USE_FAKE_STORAGE=true` for
/// widget-test harnesses that can't load `sqlite3` via ffi.
const bool _useFakeStorage = bool.fromEnvironment(
  'USE_FAKE_STORAGE',
  defaultValue: false,
);

/// Riverpod-wired backend selection. Widgets and services read
/// `ref.watch(storageProvider)` and get whichever impl the build mode
/// picked — they never see the concrete class.
///
/// The function is named `storageBackend` (not `storage`) so the class
/// `riverpod_generator` emits is [StorageBackendProvider], avoiding a
/// clash with this file's own abstract [StorageProvider] interface.
/// Consumers read through the [storageProvider] alias below.
@Riverpod(keepAlive: true)
StorageProvider storageBackend(Ref ref) {
  if (_useFakeStorage) {
    final InMemoryStorageProvider fake = InMemoryStorageProvider();
    ref.onDispose(fake.dispose);
    return fake;
  }
  final DriftStorageProvider real =
      DriftStorageProvider(HoldcloseDatabase.open());
  ref.onDispose(real.close);
  return real;
}

/// Natural-language alias for the generated provider. Consumers should
/// always reach for this name — `storageBackendProvider` exists only
/// because of the riverpod_generator class-naming collision documented
/// on [storageBackend].
final StorageBackendProvider storageProvider = storageBackendProvider;

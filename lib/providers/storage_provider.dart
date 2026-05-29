import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../db/tables.dart';
import '../models/journal_entry.dart';
import '../models/patient.dart';
import '../models/settings.dart';

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
  /// Stream entries created within [window] of "now", newest first.
  /// Re-emits whenever the underlying store changes.
  Stream<List<JournalEntry>> watchJournalEntries({Duration window});

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

  /// The single configured loved one, or null if onboarding hasn't
  /// populated one yet.
  Future<Patient?> getPatient();

  /// Insert-or-replace the single patient row by [patient.id].
  Future<void> upsertPatient(Patient patient);

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

/// Real impl backed by a [CareblazersDatabase] (BUILD_SPEC.md §6.2).
///
/// Each freezed model is serialised to its `toJson` shape and parked in
/// the row's `payload` column — see `lib/db/tables.dart` for the
/// rationale. The [JournalEntriesTable] additionally lifts
/// `createdAtMs` to its own column so the windowed watch query filters
/// + orders without parsing every blob.
class DriftStorageProvider implements StorageProvider {
  DriftStorageProvider(this._db);

  final CareblazersDatabase _db;

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
  Future<JournalEntry> insertJournalEntry(JournalEntry entry) async {
    await _db.into(_db.journalEntriesTable).insertOnConflictUpdate(
          JournalEntriesTableCompanion.insert(
            id: entry.id,
            createdAtMs: entry.createdAt.millisecondsSinceEpoch,
            payload: jsonEncode(entry.toJson()),
          ),
        );
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
  }

  @override
  Future<void> deleteJournalEntry(String id) async {
    await (_db.delete(_db.journalEntriesTable)
          ..where((t) => t.id.equals(id)))
        .go();
  }

  @override
  Future<Patient?> getPatient() async {
    final PatientsTableData? row =
        await (_db.select(_db.patientsTable)..limit(1)).getSingleOrNull();
    if (row == null) return null;
    return Patient.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  @override
  Future<void> upsertPatient(Patient patient) async {
    await _db.into(_db.patientsTable).insertOnConflictUpdate(
          PatientsTableCompanion.insert(
            id: patient.id,
            payload: jsonEncode(patient.toJson()),
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
class InMemoryStorageProvider implements StorageProvider {
  InMemoryStorageProvider({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, JournalEntry> _entries = <String, JournalEntry>{};
  Patient? _patient;
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
  Future<JournalEntry> insertJournalEntry(JournalEntry entry) async {
    _entries[entry.id] = entry;
    _notify();
    return entry;
  }

  @override
  Future<void> updateJournalEntry(JournalEntry entry) async {
    if (!_entries.containsKey(entry.id)) return;
    _entries[entry.id] = entry;
    _notify();
  }

  @override
  Future<void> deleteJournalEntry(String id) async {
    if (_entries.remove(id) != null) _notify();
  }

  @override
  Future<Patient?> getPatient() async => _patient;

  @override
  Future<void> upsertPatient(Patient patient) async {
    _patient = patient;
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
    _patient = null;
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
      DriftStorageProvider(CareblazersDatabase.open());
  ref.onDispose(real.close);
  return real;
}

/// Natural-language alias for the generated provider. Consumers should
/// always reach for this name — `storageBackendProvider` exists only
/// because of the riverpod_generator class-naming collision documented
/// on [storageBackend].
final StorageBackendProvider storageProvider = storageBackendProvider;

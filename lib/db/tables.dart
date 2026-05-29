import 'package:drift/drift.dart';

/// One auto-logged decoder run, mirroring [JournalEntry] (BUILD_SPEC.md
/// §6.2 + §7.5). Stored as an opaque JSON [payload] keyed by [id], with
/// [createdAtMs] lifted to its own column so the watch query can filter
/// + order without parsing every row's blob.
///
/// Single-row queries (insert / update / delete by id) round-trip the
/// full [JournalEntry] through [JournalEntry.toJson]; the blob shape
/// follows the freezed model exactly so any model field added later is
/// persisted automatically.
class JournalEntriesTable extends Table {
  @override
  String get tableName => 'journal_entries';

  TextColumn get id => text()();
  IntColumn get createdAtMs => integer()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// The single "loved one" the install is configured for (BUILD_SPEC.md
/// §5.9 + §9.1). One row per install — the storage layer exposes
/// `getPatient()` / `upsertPatient(...)` rather than collection CRUD.
///
/// [payload] holds the freezed [Patient] as JSON, keyed by [id] so a
/// future multi-patient model can land without a migration.
class PatientsTable extends Table {
  @override
  String get tableName => 'patients';

  TextColumn get id => text()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Persisted [AppSettings] — single row, [id] fixed to
/// [appSettingsSingletonId] (BUILD_SPEC.md §5.10 + §6.2). Stored as a
/// JSON [payload] so new preference fields don't require a schema bump.
class AppSettingsTable extends Table {
  @override
  String get tableName => 'app_settings';

  TextColumn get id => text()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Fixed primary key for the lone row in [AppSettingsTable]. The single-
/// row layout intentionally mirrors the single-patient layout — both
/// are "one user, one install" facts in v1.
const String appSettingsSingletonId = 'singleton';

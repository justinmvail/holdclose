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

/// One persisted dementia-care chat thread (TASKS.md Phase 11.2). Each
/// row carries the full freezed [Conversation] as a JSON [payload] so
/// new fields on the model don't require a schema bump; [createdAtMs]
/// and [updatedAtMs] are lifted to their own columns so the
/// most-recent-activity sort in `listConversations()` doesn't parse
/// every row's blob.
///
/// Companion table [ChatMessagesTable] holds the turn-by-turn rows
/// with an ON DELETE CASCADE FK on [id], so `deleteConversation()`
/// leaves zero orphaned messages.
class ChatConversationsTable extends Table {
  @override
  String get tableName => 'chat_conversations';

  TextColumn get id => text()();
  IntColumn get createdAtMs => integer()();
  IntColumn get updatedAtMs => integer()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One turn in a chat thread (TASKS.md Phase 11.2). FK on
/// [conversationId] references [ChatConversationsTable.id] with
/// `ON DELETE CASCADE` — deleting the parent conversation removes
/// every row that points at it, which is the cascade invariant the
/// repository tests pin.
///
/// SQLite only honours that FK action when the per-connection
/// `PRAGMA foreign_keys = ON` is set; [CareblazersDatabase]'s
/// `MigrationStrategy.beforeOpen` enables it on every connection so
/// production + tests share the same enforcement.
///
/// The freezed [Message] body lives in [payload] as JSON;
/// [createdAtMs] is lifted out so `loadMessages()` can sort the
/// thread chronologically without parsing every blob.
class ChatMessagesTable extends Table {
  @override
  String get tableName => 'chat_messages';

  TextColumn get id => text()();
  TextColumn get conversationId => text().references(
        ChatConversationsTable,
        #id,
        onDelete: KeyAction.cascade,
      )();
  IntColumn get createdAtMs => integer()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// Drift-managed SQLite database (BUILD_SPEC.md §6.2 + TASKS.md
/// Phase 11.2). Holds five tables: `journal_entries` (auto-logged
/// decoder runs), `patients` (the loved one — one row per install),
/// `app_settings` (single-row preferences blob), and the chat pair
/// `chat_conversations` + `chat_messages` (Phase 11 dementia-care
/// chatbot history, FK-linked with `ON DELETE CASCADE`).
///
/// Construct with [CareblazersDatabase.open] in production — it lazily
/// opens a SQLite file under the platform's app-documents directory via
/// `drift_flutter`. Tests pass a `NativeDatabase.memory()` directly to
/// the unnamed constructor so each test gets an isolated DB.
@DriftDatabase(
  tables: <Type>[
    JournalEntriesTable,
    PatientsTable,
    AppSettingsTable,
    ChatConversationsTable,
    ChatMessagesTable,
  ],
)
class CareblazersDatabase extends _$CareblazersDatabase {
  CareblazersDatabase(super.executor);

  /// Opens the on-device SQLite file named `careblazers.sqlite` in the
  /// platform's app-documents directory. Used by production wiring;
  /// tests bypass this in favour of `NativeDatabase.memory()`.
  factory CareblazersDatabase.open() => CareblazersDatabase(
        driftDatabase(name: 'careblazers'),
      );

  @override
  int get schemaVersion => 2;

  /// Migration handler. Two responsibilities:
  ///
  /// - On upgrade from v1 → v2, create the two chat tables. Existing
  ///   v1 installs (journal + patient + settings already populated)
  ///   keep their data; the chatbot just lights up with an empty
  ///   history.
  /// - On every open — fresh or upgraded — set
  ///   `PRAGMA foreign_keys = ON`. SQLite ships with FK enforcement
  ///   off by default; without this pragma the `ON DELETE CASCADE` on
  ///   [ChatMessagesTable] is a no-op and orphan messages survive a
  ///   conversation delete. The pragma is connection-scoped, so it
  ///   has to be set in `beforeOpen`, not `onCreate`.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            await m.createTable(chatConversationsTable);
            await m.createTable(chatMessagesTable);
          }
        },
        beforeOpen: (OpeningDetails details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// Truncate every table — backs `StorageProvider.reset()` for the
  /// demo-mode "Reset on launch" toggle (BUILD_SPEC.md §6.2 + §9.3).
  /// Chat messages are deleted before chat conversations so the wipe
  /// is FK-safe even on connections where the pragma somehow didn't
  /// stick.
  Future<void> wipeAll() async {
    await transaction(() async {
      await delete(chatMessagesTable).go();
      await delete(chatConversationsTable).go();
      await delete(journalEntriesTable).go();
      await delete(patientsTable).go();
      await delete(appSettingsTable).go();
    });
  }
}

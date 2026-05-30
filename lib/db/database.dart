import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// Drift-managed SQLite database (BUILD_SPEC.md §6.2 + TASKS.md
/// Phase 11.2 + Phase 12.1 + Phase 12.5). Holds ten tables:
/// `journal_entries` (auto-logged decoder runs), `patients` (the loved
/// one — one row per install), `app_settings` (single-row preferences
/// blob), the chat pair `chat_conversations` + `chat_messages`
/// (Phase 11 dementia-care chatbot history), the medication-tracker
/// trio `medications` + `dose_schedules` + `dose_logs` (Phase 12.1),
/// and the appointment pair `providers` + `appointments` (Phase 12.5)
/// — all FK-linked with `ON DELETE CASCADE`.
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
    MedicationsTable,
    DoseSchedulesTable,
    DoseLogsTable,
    ProvidersTable,
    AppointmentsTable,
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
  int get schemaVersion => 4;

  /// Migration handler. Four responsibilities:
  ///
  /// - On upgrade from v1 → v2, create the two chat tables. Existing
  ///   v1 installs (journal + patient + settings already populated)
  ///   keep their data; the chatbot just lights up with an empty
  ///   history.
  /// - On upgrade from v2 → v3, create the three medication-tracker
  ///   tables (Phase 12.1). Existing chat + journal data is untouched;
  ///   the medication list lights up empty.
  /// - On upgrade from v3 → v4, create the two appointment-tracker
  ///   tables (Phase 12.5). Existing data is untouched; the
  ///   appointment list lights up empty.
  /// - On every open — fresh or upgraded — set
  ///   `PRAGMA foreign_keys = ON`. SQLite ships with FK enforcement
  ///   off by default; without this pragma the `ON DELETE CASCADE` on
  ///   [ChatMessagesTable] / [DoseSchedulesTable] / [DoseLogsTable] /
  ///   [AppointmentsTable] is a no-op and orphan rows survive a parent
  ///   delete. The pragma is connection-scoped, so it has to be set in
  ///   `beforeOpen`, not `onCreate`.
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
          if (from < 3) {
            await m.createTable(medicationsTable);
            await m.createTable(doseSchedulesTable);
            await m.createTable(doseLogsTable);
          }
          if (from < 4) {
            await m.createTable(providersTable);
            await m.createTable(appointmentsTable);
          }
        },
        beforeOpen: (OpeningDetails details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// Truncate every table — backs `StorageProvider.reset()` for the
  /// demo-mode "Reset on launch" toggle (BUILD_SPEC.md §6.2 + §9.3).
  /// Child tables are deleted before their parents so the wipe is
  /// FK-safe even on connections where the pragma somehow didn't
  /// stick.
  Future<void> wipeAll() async {
    await transaction(() async {
      await delete(chatMessagesTable).go();
      await delete(chatConversationsTable).go();
      await delete(doseLogsTable).go();
      await delete(doseSchedulesTable).go();
      await delete(medicationsTable).go();
      await delete(appointmentsTable).go();
      await delete(providersTable).go();
      await delete(journalEntriesTable).go();
      await delete(patientsTable).go();
      await delete(appSettingsTable).go();
    });
  }
}

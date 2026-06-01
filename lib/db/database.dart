import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// Drift-managed SQLite database (BUILD_SPEC.md §6.2 + TASKS.md
/// Phase 11.2 + Phase 12.1 + Phase 12.5 + Phase 14.16 + Phase 14.18 +
/// Phase 14.21).
/// Holds seventeen tables:
/// `journal_entries` (auto-logged decoder runs), `patients` (the loved
/// one — one row per install), `app_settings` (single-row preferences
/// blob), the chat pair `chat_conversations` + `chat_messages`
/// (Phase 11 dementia-care chatbot history), the medication-tracker
/// trio `medications` + `dose_schedules` + `dose_logs` (Phase 12.1),
/// the appointment pair `providers` + `appointments` (Phase 12.5)
/// — all FK-linked with `ON DELETE CASCADE` — the two standalone
/// tables `health_log_entries` (Phase 14.16) and `care_plan_sections`
/// (Phase 14.18), the three documents tables `emergency_cards` +
/// `power_of_attorney_docs` + `identification_docs` (Phase 14.21), and
/// the care-circle pair `caregivers` + `care_circle_memberships`
/// (Phase 14.25) — FK-linked with `ON DELETE CASCADE` — the shared-calendar
/// table `care_events` (Phase 14.29), and the Care Team task board
/// `care_tasks` (Phase 14.30).
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
    HealthLogEntriesTable,
    CarePlanSectionsTable,
    EmergencyCardsTable,
    PowerOfAttorneyDocsTable,
    IdentificationDocsTable,
    CaregiversTable,
    CareCircleMembershipsTable,
    CareEventsTable,
    CareTasksTable,
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
  int get schemaVersion => 10;

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
  /// - On upgrade from v4 → v5, create the health-log table
  ///   (Phase 14.16). Existing data is untouched; the health log lights
  ///   up empty.
  /// - On upgrade from v5 → v6, create the care-plan table
  ///   (Phase 14.18). Existing data is untouched; the care plan lights
  ///   up empty.
  /// - On upgrade from v6 → v7, create the three documents tables
  ///   (Phase 14.21). Existing data is untouched; Cards & Documents
  ///   lights up empty.
  /// - On upgrade from v7 → v8, create the care-circle pair
  ///   (Phase 14.25). Existing data is untouched; the Care Circle roster
  ///   lights up empty (just the owner).
  /// - On upgrade from v8 → v9, create the calendar table
  ///   (Phase 14.29). Existing data is untouched; the shared calendar
  ///   lights up with just the projected appointments (no native notes
  ///   yet).
  /// - On upgrade from v9 → v10, create the care-tasks table
  ///   (Phase 14.30). Existing data is untouched; the Care Team task
  ///   board lights up empty.
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
          if (from < 5) {
            await m.createTable(healthLogEntriesTable);
          }
          if (from < 6) {
            await m.createTable(carePlanSectionsTable);
          }
          if (from < 7) {
            await m.createTable(emergencyCardsTable);
            await m.createTable(powerOfAttorneyDocsTable);
            await m.createTable(identificationDocsTable);
          }
          if (from < 8) {
            await m.createTable(caregiversTable);
            await m.createTable(careCircleMembershipsTable);
          }
          if (from < 9) {
            await m.createTable(careEventsTable);
          }
          if (from < 10) {
            await m.createTable(careTasksTable);
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
      await delete(healthLogEntriesTable).go();
      await delete(carePlanSectionsTable).go();
      await delete(emergencyCardsTable).go();
      await delete(powerOfAttorneyDocsTable).go();
      await delete(identificationDocsTable).go();
      await delete(careCircleMembershipsTable).go();
      await delete(caregiversTable).go();
      await delete(careEventsTable).go();
      await delete(careTasksTable).go();
      await delete(journalEntriesTable).go();
      await delete(patientsTable).go();
      await delete(appSettingsTable).go();
    });
  }
}

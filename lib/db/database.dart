import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'tables.dart';

part 'database.g.dart';

/// Drift-managed SQLite database (BUILD_SPEC.md §6.2 + TASKS.md
/// Phase 11.2 + Phase 12.1 + Phase 12.5 + Phase 14.16 + Phase 14.18 +
/// Phase 14.21).
/// Holds seventeen tables:
/// `journal_entries` (auto-logged decoder runs), `patients` (the loved
/// one — one row per install), `app_settings` (single-row preferences
/// blob), the chat pair `chat_conversations` + `chat_messages`
/// (Phase 11 caregiving chatbot history), the medication-tracker
/// trio `medications` + `dose_schedules` + `dose_logs` (Phase 12.1),
/// the appointment pair `providers` + `appointments` (Phase 12.5)
/// — all FK-linked with `ON DELETE CASCADE` — the two standalone
/// tables `health_log_entries` (Phase 14.16) and `care_plan_sections`
/// (Phase 14.18), the three documents tables `emergency_cards` +
/// `power_of_attorney_docs` + `identification_docs` (Phase 14.21), and
/// the care-circle pair `caregivers` + `care_circle_memberships`
/// (Phase 14.25) — FK-linked with `ON DELETE CASCADE` — the shared-calendar
/// table `care_events` (Phase 14.29), the Care Team task board
/// `care_tasks` (Phase 14.30), and the Care Team shift coverage board
/// `care_shifts` (Phase 14.31).
///
/// Construct with [HoldcloseDatabase.open] in production — it lazily
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
    DoseWindowsTable,
    MedicationWindowEntriesTable,
    DoseLogsTable,
    ProvidersTable,
    AppointmentsTable,
    HealthLogEntriesTable,
    CarePlanRoutinesTable,
    EmergencyCardsTable,
    PowerOfAttorneyDocsTable,
    IdentificationDocsTable,
    CaregiversTable,
    CareCircleMembershipsTable,
    CareEventsTable,
    CareTasksTable,
    CareShiftsTable,
    ExpensesTable,
    SyncOutboxTable,
    CircleMemberCacheTable,
    ForumPostCacheTable,
  ],
)
class HoldcloseDatabase extends _$HoldcloseDatabase {
  HoldcloseDatabase(super.executor) : _isShared = false;

  /// Private ctor for the app-wide shared singleton ([open]). Its [close]
  /// is a no-op so one provider's `ref.onDispose(db.close)` can't tear down
  /// the connection that every other provider + the sync engine share.
  HoldcloseDatabase._shared(super.executor) : _isShared = true;

  /// True only for the process-wide shared instance returned by [open].
  final bool _isShared;

  /// The one shared on-disk connection (see [open]).
  static HoldcloseDatabase? _sharedInstance;

  /// Opens the on-device SQLite file named `holdclose.sqlite` in the
  /// platform's app-documents directory — returning a PROCESS-WIDE SINGLETON
  /// so every production caller (each repository/provider AND the sync
  /// engine) shares ONE connection. Drift serialises writes on a single
  /// connection, which eliminates the `SQLITE_BUSY` "database is locked"
  /// failures that struck when separate connections wrote concurrently
  /// (e.g. a chat/setup write racing the sync engine). Tests bypass this in
  /// favour of `NativeDatabase.memory()`.
  factory HoldcloseDatabase.open() =>
      openShared(driftDatabase(name: 'holdclose'));

  /// The memoisation behind [open], with an injectable [executor] so the
  /// singleton + no-op-close behaviour is testable without the platform
  /// path_provider that the real `driftDatabase(...)` needs. Production
  /// calls [open]; tests call this with an on-disk `NativeDatabase`.
  /// Returns the existing shared instance if one was already opened — the
  /// passed [executor] is then ignored, which is the whole point (one
  /// connection for the process).
  @visibleForTesting
  static HoldcloseDatabase openShared(QueryExecutor executor) =>
      _sharedInstance ??= HoldcloseDatabase._shared(executor);

  /// Drop the shared singleton so a test can open a fresh one. No-op in
  /// production (nothing calls it).
  @visibleForTesting
  static void resetSharedForTest() {
    _sharedInstance = null;
  }

  @override
  Future<void> close() {
    // The shared singleton lives for the whole process; a provider's
    // `ref.onDispose(db.close)` must NOT close the connection everyone else
    // is still using. Test/in-memory instances close normally.
    if (_isShared) return Future<void>.value();
    return super.close();
  }

  /// Builds a fresh database backed entirely by `NativeDatabase.memory()`
  /// — no on-disk SQLite file, no shared app-documents path. Each call
  /// returns an isolated connection, so two instances never see each
  /// other's rows; the [migration] strategy runs `onCreate` against the
  /// blank in-memory file, materialising every table at the current
  /// [schemaVersion]. Backs the Phase 15 integration harness
  /// (`test/integration/test_harness.dart`) and every Phase 15 `test/db/`
  /// case — the caller is responsible for `.close()` in a teardown so the
  /// connection doesn't outlive the test (TASKS.md Phase 15.2).
  factory HoldcloseDatabase.testInstance() =>
      HoldcloseDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => 20;

  /// One-shot repair for the rows v15 stranded (see the v20 migration
  /// step): window entries whose dose window no longer exists. Visible
  /// so the repair can be unit-tested against a hand-built orphan state
  /// without re-running a version upgrade.
  @visibleForTesting
  static const String cleanupOrphanedWindowEntriesSql =
      'DELETE FROM medication_window_entries '
      'WHERE window_id NOT IN (SELECT id FROM dose_windows)';

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
  /// - On upgrade from v10 → v11, create the care-shifts table
  ///   (Phase 14.31). Existing data is untouched; the Care Team shift
  ///   coverage board lights up empty.
  /// - On upgrade from v11 → v12, create the expenses table
  ///   (Phase 14.33). Existing data is untouched; the Care Team expenses
  ///   ledger lights up empty.
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
            // v3 originally created `dose_schedules` alongside
            // medications + dose_logs. dose_schedules is dropped at v14
            // when the medication tracker pivots to window-driven
            // scheduling, so the v3 step here skips it — v14's
            // CREATE owns the new tables.
            await m.createTable(medicationsTable);
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
            // v6 originally created `CarePlanSectionsTable`. That table is
            // dropped at v13; for v1 installs upgrading straight through,
            // there's no point creating then dropping. v6 → v13 is a
            // no-op step here so the subsequent CREATE in the v13 block
            // owns the routines table.
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
          if (from < 11) {
            await m.createTable(careShiftsTable);
          }
          if (from < 12) {
            await m.createTable(expensesTable);
          }
          if (from < 13) {
            // Care Plan v2: drop the old slot/stage `CarePlanSectionsTable`
            // and replace with the wall-clock-scheduled
            // [CarePlanRoutinesTable]. The v1 data was organisational
            // notes that don't map cleanly onto the new model — wipe + let
            // the caregiver re-author routines as scheduled tasks. The
            // schema is too freshly seeded in v1 for this to matter in
            // practice.
            await customStatement('DROP TABLE IF EXISTS care_plan_sections');
            await m.createTable(carePlanRoutinesTable);
          }
          if (from < 14) {
            // Medication scheduling v2: pivot from per-medication
            // [DoseSchedulesTable] (frequency + timesOfDay × per-med) to
            // per-window [DoseWindowsTable] + [MedicationWindowEntriesTable].
            // The pillbox-shaped model matches how caregivers actually
            // think ("what does Mom take in the morning?"). v1 schedule
            // rows aren't migrated — the schema is freshly seeded in v1
            // and the seed wires the new windows directly.
            await customStatement('DROP TABLE IF EXISTS dose_schedules');
            await m.createTable(doseWindowsTable);
            await m.createTable(medicationWindowEntriesTable);
          }
          if (from < 15) {
            // Drop the seeded Morning / Noon / Evening / Bedtime /
            // As-needed windows the v14 bootstrap auto-created — the
            // caregiver wanted to manage windows themselves rather
            // than inherit a default set. FK cascade wipes any
            // medication entries linked to those windows; the
            // medications themselves stay (the FK on entries points
            // to medications, but the cascade only fires when the
            // *medication* row goes away). Idempotent — a fresh v15
            // install never holds these rows, so the DELETE is a
            // no-op.
            await customStatement(
              "DELETE FROM dose_windows WHERE id IN ("
              "'window-demo-patient-mary-morning',"
              "'window-demo-patient-mary-noon',"
              "'window-demo-patient-mary-evening',"
              "'window-demo-patient-mary-bedtime',"
              "'window-demo-patient-mary-as-needed'"
              ")",
            );
          }
          if (from < 16) {
            // Server-authoritative sync: create the outbound queue table.
            // Existing data is untouched; the queue lights up empty and
            // only fills once the install joins/creates a care circle.
            await m.createTable(syncOutboxTable);
          }
          if (from < 17) {
            // Document scan blobs: add nullable R2 storage-key columns
            // paralleling each on-disk image path so the scans survive a
            // reinstall and sync across the care circle (the path alone is
            // meaningless on another device). Existing rows get NULL keys
            // and keep working off their local paths; a key is filled in
            // best-effort on the next save / sync.
            await m.addColumn(
              emergencyCardsTable,
              emergencyCardsTable.attachmentKey,
            );
            await m.addColumn(
              powerOfAttorneyDocsTable,
              powerOfAttorneyDocsTable.attachmentKey,
            );
            await m.addColumn(
              powerOfAttorneyDocsTable,
              powerOfAttorneyDocsTable.scanKey,
            );
            await m.addColumn(
              identificationDocsTable,
              identificationDocsTable.attachmentKey,
            );
            await m.addColumn(
              identificationDocsTable,
              identificationDocsTable.photoFrontKey,
            );
            await m.addColumn(
              identificationDocsTable,
              identificationDocsTable.photoBackKey,
            );
          }
          if (from < 18) {
            // Local-first Care Circle: a read-cache of the backend circle
            // roster so the People screen renders offline instead of hitting
            // `GET /circles` live. Lights up empty; fills on the next sync.
            await m.createTable(circleMemberCacheTable);
          }
          if (from < 19) {
            // Local-first community feed: a read-cache of the forum's first
            // page so Community renders the last-seen posts offline instead of
            // a "couldn't load" error. Lights up empty; fills on first load.
            await m.createTable(forumPostCacheTable);
          }
          if (from < 20) {
            // (a) Secondary indices on the hot FK/sort columns. SQLite
            // does NOT auto-index FK children, so every chat-thread
            // load, dose query, and ON DELETE CASCADE was a full table
            // scan over tables that grow for the life of the install.
            // Fresh installs get these from the @TableIndex annotations
            // at create time; this step backfills upgrades.
            await m.createIndex(chatMessagesConversationIdx);
            await m.createIndex(medicationWindowEntriesWindowIdx);
            await m.createIndex(medicationWindowEntriesMedicationIdx);
            await m.createIndex(doseLogsMedicationScheduledIdx);
            await m.createIndex(journalEntriesCreatedIdx);
            await m.createIndex(healthLogEntriesPatientRecordedIdx);
            // (b) Repair v15's orphans. v15 deleted the seeded windows
            // assuming "FK cascade wipes any medication entries linked
            // to those windows" — but `PRAGMA foreign_keys = ON` runs in
            // beforeOpen, AFTER onUpgrade, so the cascade never fired
            // during that migration and the window entries became
            // permanent orphans (invisible to window-driven reads but
            // still returned by entriesForMedication).
            await customStatement(cleanupOrphanedWindowEntriesSql);
          }
        },
        beforeOpen: (OpeningDetails details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          // Production now opens exactly ONE on-disk connection — the shared
          // singleton from [open] — which is the real fix for the
          // SQLITE_BUSY "database is locked" failures that struck when each
          // repository + the sync engine opened their OWN connection and
          // wrote concurrently (a chat/setup write racing the sync engine).
          // These pragmas are kept as harmless defense-in-depth: WAL lets
          // readers run alongside the writer, and busy_timeout makes a write
          // wait-and-retry up to 5s rather than erroring if a second
          // connection ever exists again. Both are no-ops on the in-memory
          // test database.
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA busy_timeout = 5000');
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
      await delete(medicationWindowEntriesTable).go();
      await delete(doseWindowsTable).go();
      await delete(medicationsTable).go();
      await delete(appointmentsTable).go();
      await delete(providersTable).go();
      await delete(healthLogEntriesTable).go();
      await delete(carePlanRoutinesTable).go();
      await delete(emergencyCardsTable).go();
      await delete(powerOfAttorneyDocsTable).go();
      await delete(identificationDocsTable).go();
      await delete(careCircleMembershipsTable).go();
      await delete(caregiversTable).go();
      await delete(careEventsTable).go();
      await delete(careTasksTable).go();
      await delete(careShiftsTable).go();
      await delete(expensesTable).go();
      await delete(syncOutboxTable).go();
      await delete(circleMemberCacheTable).go();
      await delete(forumPostCacheTable).go();
      await delete(journalEntriesTable).go();
      await delete(patientsTable).go();
      await delete(appSettingsTable).go();
    });
  }
}

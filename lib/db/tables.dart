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

/// One tracked medication (TASKS.md Phase 12.1).
///
/// The structured counterpart to the free-text crisis-card meds in
/// [PatientsTable] — this row carries the id every [DoseSchedulesTable]
/// and [DoseLogsTable] row FKs onto. The full freezed `Medication`
/// model lives in [payload] as JSON; [name] is lifted to its own
/// column so the medication-list screen (Phase 12.3) can sort
/// alphabetically without parsing every blob.
class MedicationsTable extends Table {
  @override
  String get tableName => 'medications';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One dosing schedule for a [MedicationsTable] row (TASKS.md Phase
/// 12.1). FK on [medicationId] references [MedicationsTable.id] with
/// `ON DELETE CASCADE` — wiping a medication wipes its schedules in
/// the same statement, so the repository never leaves orphans behind.
///
/// SQLite only honours that FK action when the per-connection
/// `PRAGMA foreign_keys = ON` is set; [CareblazersDatabase]'s
/// `MigrationStrategy.beforeOpen` enables it on every connection.
///
/// The freezed `DoseSchedule` (frequencyKind + timesOfDay + daysOfWeek
/// + startsOn / endsOn) lives in [payload] as JSON.
class DoseSchedulesTable extends Table {
  @override
  String get tableName => 'dose_schedules';

  TextColumn get id => text()();
  TextColumn get medicationId => text().references(
        MedicationsTable,
        #id,
        onDelete: KeyAction.cascade,
      )();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One logged dose event (TASKS.md Phase 12.1). FK on [medicationId]
/// references [MedicationsTable.id] with `ON DELETE CASCADE` — same
/// pragma-dependent cascade as [DoseSchedulesTable].
///
/// [scheduledForMs] is lifted out of the freezed `DoseLog` payload so
/// the "today's doses" view (Phase 12.4) and the adherence-rate
/// computation (Phase 12.2) can filter + order on the scheduled time
/// without parsing every row.
class DoseLogsTable extends Table {
  @override
  String get tableName => 'dose_logs';

  TextColumn get id => text()();
  TextColumn get medicationId => text().references(
        MedicationsTable,
        #id,
        onDelete: KeyAction.cascade,
      )();
  IntColumn get scheduledForMs => integer()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One healthcare provider the caregiver coordinates with (TASKS.md
/// Phase 12.5).
///
/// The structured counterpart to the free-text crisis-card contacts
/// in [PatientsTable] — this row carries the id every
/// [AppointmentsTable] row FKs onto. The full freezed `Provider` model
/// lives in [payload] as JSON; [name] is lifted to its own column so
/// the appointment + provider screens (Phase 12.6 / 12.7) can sort
/// alphabetically without parsing every blob.
class ProvidersTable extends Table {
  @override
  String get tableName => 'providers';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One scheduled (or past) visit with a [ProvidersTable] row (TASKS.md
/// Phase 12.5). FK on [providerId] references [ProvidersTable.id] with
/// `ON DELETE CASCADE` — wiping a provider wipes its appointments in
/// the same statement, so the repository never leaves orphans behind.
///
/// SQLite only honours that FK action when the per-connection
/// `PRAGMA foreign_keys = ON` is set; [CareblazersDatabase]'s
/// `MigrationStrategy.beforeOpen` enables it on every connection.
///
/// [startsAtMs] is lifted out of the freezed `Appointment` payload so
/// the list screen (Phase 12.6) can group + order by date without
/// parsing every blob.
class AppointmentsTable extends Table {
  @override
  String get tableName => 'appointments';

  TextColumn get id => text()();
  TextColumn get providerId => text().references(
        ProvidersTable,
        #id,
        onDelete: KeyAction.cascade,
      )();
  IntColumn get startsAtMs => integer()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One health-log row for the loved one (TASKS.md Phase 14.16).
///
/// Backs Medical → Health Log (BUILD_SPEC.md §5.13). The full freezed
/// `HealthLogEntry` (kind + severity + vitals + notes) lives in
/// [payload] as JSON — same blob-with-lifted-keys pattern the journal,
/// chat, medication, and appointment tables use, so a new model field
/// is persisted automatically without a schema bump.
///
/// Two keys are lifted out of the blob so the common reads don't parse
/// every row: [recordedAtMs] (the `todayByKind` / recency queries order
/// + filter on it) and [patientId] (the `byPatient` query filters on
/// it). Unlike the appointment / medication tables there's no DB-level
/// foreign key onto [PatientsTable]: that table is single-row ("one
/// loved one per install"), so a cascade buys nothing, and keeping the
/// link logical leaves room for a future multi-patient model to land
/// without reworking the FK graph.
class HealthLogEntriesTable extends Table {
  @override
  String get tableName => 'health_log_entries';

  TextColumn get id => text()();
  TextColumn get patientId => text()();
  IntColumn get recordedAtMs => integer()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One section of the loved one's care plan (TASKS.md Phase 14.18).
///
/// Backs Medical → Care Plan (BUILD_SPEC.md §5.13). The full freezed
/// `CarePlanSection` (slot + title + body markdown + appliesInStage)
/// lives in [payload] as JSON — same blob-with-lifted-keys pattern the
/// journal, chat, medication, appointment, and health-log tables use, so
/// a new model field is persisted automatically without a schema bump.
///
/// Three keys are lifted out of the blob so the common reads never parse
/// a payload: [slot] and [orderIndex] (the `bySlot` query filters on the
/// slot and orders within it by index — the care-plan provider keeps
/// those indices contiguous and duplicate-free per slot), and
/// [patientId] (room for a future `byPatient` filter). Like the
/// health-log table there's no DB-level foreign key onto [PatientsTable]:
/// that table is single-row ("one loved one per install"), so a cascade
/// buys nothing and the [patientId] link stays logical.
class CarePlanSectionsTable extends Table {
  @override
  String get tableName => 'care_plan_sections';

  TextColumn get id => text()();
  TextColumn get patientId => text()();
  TextColumn get slot => text()();
  IntColumn get orderIndex => integer()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// The loved one's emergency / hospital-handoff card (TASKS.md Phase
/// 14.21).
///
/// Backs Medical → Cards & Documents → Emergency Card (BUILD_SPEC.md
/// §5.17). Unlike the journal / chat / medication tables — which blob the
/// whole freezed model into a single `payload` column — this table breaks
/// the [EmergencyCard] fields into typed columns so each is queryable
/// straight from SQLite. The three string lists ([conditions] /
/// [medications] / [allergies]) and the [emergencyContacts] / [insurance]
/// structures don't have a native column type, so they're stored as
/// JSON-encoded TEXT; the repository (`lib/providers/documents_provider
/// .dart`) owns that encode/decode at the boundary. [donorStatus] is the
/// enum's `.name`; [updatedAtMs] is the epoch-ms of `updatedAt`.
///
/// [patientId] is a logical link to [PatientsTable], not a DB foreign
/// key — that table is single-row ("one loved one per install"), so a
/// cascade buys nothing and the link stays logical (mirroring the
/// health-log + care-plan tables).
class EmergencyCardsTable extends Table {
  @override
  String get tableName => 'emergency_cards';

  TextColumn get id => text()();
  TextColumn get patientId => text()();
  IntColumn get updatedAtMs => integer()();
  TextColumn get attachmentPath => text().nullable()();

  /// JSON-encoded `List<String>`.
  TextColumn get conditions => text()();
  TextColumn get medications => text()();
  TextColumn get allergies => text()();

  /// JSON-encoded `List<{name, relation, phone}>`.
  TextColumn get emergencyContacts => text()();

  /// JSON-encoded `{carrier, policyNumber, groupNumber}`.
  TextColumn get insurance => text()();

  /// [DonorStatus] enum `.name`.
  TextColumn get donorStatus => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// A power-of-attorney document on file for the loved one (TASKS.md
/// Phase 14.21).
///
/// Backs Medical → Cards & Documents (BUILD_SPEC.md §5.17). Typed-column
/// schema like [EmergencyCardsTable]: [scope] is the [PoaScope] enum's
/// `.name`, [effectiveDateMs] / [updatedAtMs] are epoch-ms, and the
/// optional [alternateName] / [scanPath] / [attachmentPath] are nullable
/// TEXT. [patientId] is a logical link to [PatientsTable] (no DB FK — see
/// [EmergencyCardsTable]).
class PowerOfAttorneyDocsTable extends Table {
  @override
  String get tableName => 'power_of_attorney_docs';

  TextColumn get id => text()();
  TextColumn get patientId => text()();
  IntColumn get updatedAtMs => integer()();
  TextColumn get attachmentPath => text().nullable()();

  TextColumn get agentName => text()();
  TextColumn get alternateName => text().nullable()();

  /// [PoaScope] enum `.name`.
  TextColumn get scope => text()();
  IntColumn get effectiveDateMs => integer()();
  TextColumn get scanPath => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// An identification document captured for the loved one (TASKS.md Phase
/// 14.21).
///
/// Backs Medical → Cards & Documents (BUILD_SPEC.md §5.17). Typed-column
/// schema like [EmergencyCardsTable]: [kind] is the [IdKind] enum's
/// `.name`, [updatedAtMs] is epoch-ms, the optional [expiresOnMs] is a
/// nullable epoch-ms, and the photo / attachment pointers are nullable
/// TEXT. [patientId] is a logical link to [PatientsTable] (no DB FK — see
/// [EmergencyCardsTable]).
class IdentificationDocsTable extends Table {
  @override
  String get tableName => 'identification_docs';

  TextColumn get id => text()();
  TextColumn get patientId => text()();
  IntColumn get updatedAtMs => integer()();
  TextColumn get attachmentPath => text().nullable()();

  /// [IdKind] enum `.name`.
  TextColumn get kind => text()();
  TextColumn get idNumber => text()();
  IntColumn get expiresOnMs => integer().nullable()();
  TextColumn get photoFrontPath => text().nullable()();
  TextColumn get photoBackPath => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One caregiver in the loved one's care circle (TASKS.md Phase 14.25).
///
/// Backs Care Team → Care Circle (BUILD_SPEC.md §5.14). Typed-column
/// schema like the documents tables: [role] is the `CaregiverRole` enum's
/// `.name`, [displayName] is lifted to its own column so the roster can
/// sort alphabetically, and the optional [phone] / [email] / [avatarPath]
/// are nullable TEXT. The companion [CareCircleMembershipsTable] FKs onto
/// [id] with `ON DELETE CASCADE`, so removing a caregiver removes their
/// membership in the same statement.
class CaregiversTable extends Table {
  @override
  String get tableName => 'caregivers';

  TextColumn get id => text()();
  TextColumn get displayName => text()();

  /// `CaregiverRole` enum `.name`.
  TextColumn get role => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get avatarPath => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One natively-stored calendar event for the loved one (TASKS.md Phase
/// 14.29).
///
/// Backs Care Team → Calendar (BUILD_SPEC.md §5.14). The shared calendar
/// unifies four sources, but only ad-hoc **notes** ([CareEventKind.note])
/// live here — appointments, tasks, and shifts are *projected* onto the
/// calendar from their own tables at read time, so this row never
/// double-stores them. (The column shape doesn't enforce that; the
/// projection lives in `lib/providers/care_events_provider.dart`.)
///
/// Same blob-with-lifted-keys pattern the journal / appointment /
/// health-log tables use: the full freezed `CareEvent` lives in [payload]
/// as JSON so a new model field is persisted without a schema bump. Two
/// keys are lifted out so the common reads don't parse every row's blob —
/// [startMs] (the calendar orders chronologically on it) and [patientId]
/// (room for a future `byPatient` filter). Like the health-log + care-plan
/// tables there's no DB-level foreign key onto [PatientsTable]: that table
/// is single-row ("one loved one per install"), so a cascade buys nothing
/// and the [patientId] link stays logical.
class CareEventsTable extends Table {
  @override
  String get tableName => 'care_events';

  TextColumn get id => text()();
  TextColumn get patientId => text()();
  IntColumn get startMs => integer()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One shared to-do on the Care Team task board (TASKS.md Phase 14.30).
///
/// Backs Care Team → Tasks (BUILD_SPEC.md §5.14). Same
/// blob-with-lifted-keys pattern the journal / care-event tables use: the
/// full freezed `CareTask` lives in [payload] as JSON so a new model field
/// is persisted without a schema bump. Two keys are lifted out so the
/// common reads don't parse every row's blob — [dueAtMs] (nullable; the
/// board orders tasks by due time) and [patientId] (room for a future
/// `byPatient` filter). Like the health-log + care-event tables there's no
/// DB-level foreign key onto [PatientsTable]: that table is single-row
/// ("one loved one per install"), so a cascade buys nothing and the
/// [patientId] link stays logical.
///
/// The [assigneeCaregiverId] is intentionally NOT a DB foreign key onto
/// [CaregiversTable] — a task can be claimed by the signed-in caregiver
/// before any care-circle row exists for them, and a removed caregiver
/// should leave their finished tasks intact rather than cascade-deleting
/// the history. The screen resolves the assignee name softly at read time.
class CareTasksTable extends Table {
  @override
  String get tableName => 'care_tasks';

  TextColumn get id => text()();
  TextColumn get patientId => text()();
  IntColumn get dueAtMs => integer().nullable()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One caregiving shift on the Care Team coverage board (TASKS.md Phase
/// 14.31).
///
/// Backs Care Team → Shifts (BUILD_SPEC.md §5.14). Same
/// blob-with-lifted-keys pattern the journal / care-event / care-task
/// tables use: the full freezed `CareShift` lives in [payload] as JSON so
/// a new model field is persisted without a schema bump. Three keys are
/// lifted out so the per-day coverage reads don't parse every row's blob —
/// [startMs] / [endMs] (the day strip filters to the shifts whose window
/// intersects each day and clamps them onto the 24-hour bar) and
/// [patientId] (room for a future `byPatient` filter).
///
/// Like the care-task table there's no DB-level foreign key onto
/// [PatientsTable] (single-row, so a cascade buys nothing) nor onto
/// [CaregiversTable] — a shift should survive its caregiver being removed
/// from the circle rather than cascade-deleting the coverage history, so
/// the `caregiverId` inside the payload stays a logical link the screen
/// resolves softly at read time.
class CareShiftsTable extends Table {
  @override
  String get tableName => 'care_shifts';

  TextColumn get id => text()();
  TextColumn get patientId => text()();
  IntColumn get startMs => integer()();
  IntColumn get endMs => integer()();
  TextColumn get payload => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One caregiver's membership in a loved one's care circle (TASKS.md
/// Phase 14.25).
///
/// Backs Care Team → Care Circle (BUILD_SPEC.md §5.14). FK on
/// [caregiverId] references [CaregiversTable.id] with `ON DELETE CASCADE`
/// — removing a caregiver wipes their membership in the same statement,
/// so the roster never shows an orphaned permission row.
///
/// SQLite only honours that FK action when the per-connection
/// `PRAGMA foreign_keys = ON` is set; [CareblazersDatabase]'s
/// `MigrationStrategy.beforeOpen` enables it on every connection.
///
/// [permissionLevel] is the `PermissionLevel` enum's `.name`;
/// [invitedAtMs] / [acceptedAtMs] are epoch-ms ([acceptedAtMs] nullable —
/// null while the invite is pending). [patientId] is a logical link to
/// the single-row [PatientsTable] (no DB FK — see [EmergencyCardsTable]).
class CareCircleMembershipsTable extends Table {
  @override
  String get tableName => 'care_circle_memberships';

  TextColumn get id => text()();
  TextColumn get caregiverId => text().references(
        CaregiversTable,
        #id,
        onDelete: KeyAction.cascade,
      )();
  TextColumn get patientId => text()();

  /// `PermissionLevel` enum `.name`.
  TextColumn get permissionLevel => text()();
  IntColumn get invitedAtMs => integer()();
  IntColumn get acceptedAtMs => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

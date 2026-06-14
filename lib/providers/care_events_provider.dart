import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/appointment.dart';
import '../models/care_event.dart';
import '../models/care_task.dart';
import '../services/appointment_repository.dart';
import '../services/sync_sink.dart';
import 'active_patient_provider.dart';
import 'care_tasks_provider.dart';

part 'care_events_provider.g.dart';

/// Last-resort patient id used when no active loved one is on file yet.
///
/// Shared neutral fallback constant the medical + care-circle forms and the
/// appointment-event projection all reference (the appointment projection
/// FKs onto a provider, not a patient, so it stamps the single-install
/// loved one here). The string value still matches the bundled seed data so
/// DEMO_MODE / widget tests that seed records keyed on it keep resolving;
/// real installs set an explicit active patient and never persist this.
const String fallbackPatientId = 'demo-patient-mary';

/// Project one [Appointment] onto a calendar [CareEvent] (TASKS.md Phase
/// 14.29).
///
/// Read-only — the calendar never stores these; it materializes them from
/// the appointment list on every read. The block [CareEvent.title] is the
/// provider name when one resolved, falling back to the location and then
/// a bare "Appointment" label. [CareEvent.end] is `startsAt +
/// durationMinutes` so the week grid can size the block. [externalRef] is
/// the appointment id, so a tapped block routes to `/appointments/<id>`.
/// The synthetic `appt-` id prefix keeps these from colliding with the
/// native note ids in the `care_events` table.
CareEvent careEventFromAppointment(
  Appointment appointment, {
  String? providerName,
}) {
  final String resolvedName = providerName?.trim() ?? '';
  final String title = resolvedName.isNotEmpty
      ? resolvedName
      : (appointment.location.isNotEmpty
          ? appointment.location
          : 'Appointment');
  return CareEvent(
    id: 'appt-${appointment.id}',
    kind: CareEventKind.appointment,
    title: title,
    // Activity-feed-style sentence — Calendar reads only [title], so
    // the longer "Appointment with …" form lives in subtitle and the
    // Home Recent Activity card reads that.
    subtitle: 'Appointment with $title',
    start: appointment.startsAt,
    end: appointment.startsAt
        .add(Duration(minutes: appointment.durationMinutes)),
    patientId: fallbackPatientId,
    externalRef: appointment.id,
  );
}

/// Project one standalone [CareTask] onto a calendar [CareEvent] (unified
/// task/routine model, 2026-06-06).
///
/// A task is the atom and a routine is the bundle: a standalone task (one
/// with `routineId == null`) that carries a due time rides the schedule on
/// its own, exactly the way a routine occurrence does. Callers guarantee
/// [CareTask.dueAt] is non-null before projecting. The synthetic `task-`
/// id prefix keeps these from colliding with the native note ids; a tapped
/// block routes to the task list via [CareEventX.detailRoute].
CareEvent careEventFromTask(CareTask task) => CareEvent(
      id: 'task-${task.id}',
      kind: CareEventKind.task,
      title: task.title,
      start: task.dueAt!,
      ownerCaregiverId: task.assigneeCaregiverId,
      patientId: task.patientId,
      externalRef: task.id,
      subtitle: task.body,
    );

/// Persistence for the natively-stored calendar events — ad-hoc notes
/// ([CareEventKind.note]) the caregiver adds straight on the calendar
/// (TASKS.md Phase 14.29).
///
/// Appointments / tasks / shifts are projected onto the calendar from
/// their own tables (see [careEvents]); only notes round-trip through
/// here. Same blob-with-lifted-keys pattern [AppointmentRepository] uses —
/// the freezed [CareEvent] serialises into the row's `payload`, with
/// [CareEventsTable.startMs] lifted out so the chronological read doesn't
/// decode every blob.
class CareEventsRepository with SyncSinkHost {
  CareEventsRepository(this._db);

  final CareblazersDatabase _db;

  /// Close the underlying database. The riverpod provider wires this to
  /// `ref.onDispose`.
  Future<void> close() => _db.close();

  /// Insert-or-replace [event] by id.
  Future<void> upsertEvent(CareEvent event) async {
    await _db.into(_db.careEventsTable).insertOnConflictUpdate(
          CareEventsTableCompanion.insert(
            id: event.id,
            patientId: event.patientId,
            startMs: event.start.millisecondsSinceEpoch,
            payload: jsonEncode(event.toJson()),
          ),
        );
    // Only the natively-stored notes round-trip through this repository;
    // the projected appointment/task/shift CareEvents are materialized in
    // the [careEvents] provider and never written here, so they never sync.
    emitUpsert('care_events', event.id, event.toJson());
  }

  /// Drop the event with this id. No-op if absent.
  Future<void> deleteEvent(String id) async {
    await (_db.delete(_db.careEventsTable)..where((t) => t.id.equals(id)))
        .go();
    emitDelete('care_events', id);
  }

  /// One event by id, or null if absent.
  Future<CareEvent?> getEvent(String id) async {
    final CareEventsTableData? row = await (_db.select(_db.careEventsTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return CareEvent.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  /// Every natively-stored event, chronological by start.
  ///
  /// UNFILTERED across patients on purpose — the sync engine
  /// ([SyncController.resyncAllLocal]) walks this to push EVERY local note up
  /// regardless of which loved one is active. The calendar's DISPLAY read is
  /// [listEventsForPatient].
  Future<List<CareEvent>> listEvents() async {
    final List<CareEventsTableData> rows = await (_db
            .select(_db.careEventsTable)
          ..orderBy(<OrderClauseGenerator<$CareEventsTableTable>>[
            (t) => OrderingTerm(expression: t.startMs, mode: OrderingMode.asc),
          ]))
        .get();
    return rows
        .map((CareEventsTableData r) =>
            CareEvent.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  /// Natively-stored events filed under [patientId] only, chronological by
  /// start (multi-patient display scoping, Issue #6).
  ///
  /// The calendar reads THIS so a caregiver with more than one loved one on
  /// file never sees another person's notes. Filters on the lifted
  /// [CareEventsTable.patientId] column. Sync still uses the unfiltered
  /// [listEvents].
  Future<List<CareEvent>> listEventsForPatient(String patientId) async {
    final List<CareEventsTableData> rows = await (_db
            .select(_db.careEventsTable)
          ..where((t) => t.patientId.equals(patientId))
          ..orderBy(<OrderClauseGenerator<$CareEventsTableTable>>[
            (t) => OrderingTerm(expression: t.startMs, mode: OrderingMode.asc),
          ]))
        .get();
    return rows
        .map((CareEventsTableData r) =>
            CareEvent.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  /// Re-file every natively-stored note currently stamped [from] under [to],
  /// returning the number of rows moved (the one-time multi-patient
  /// migration, Issue #6).
  ///
  /// Each moved row round-trips through [upsertEvent] so the lifted
  /// [CareEventsTable.patientId] column is rewritten AND the change re-emits
  /// through the sync sink. A no-op when [from] == [to]. Only the
  /// natively-stored notes live here — the projected appointment/task/shift
  /// events aren't rows in this table, so they're untouched.
  Future<int> restampPatient(String from, String to) async {
    if (from == to) return 0;
    final List<CareEvent> events = await listEventsForPatient(from);
    for (final CareEvent event in events) {
      await upsertEvent(event.copyWith(patientId: to));
    }
    return events.length;
  }
}

/// Riverpod-wired singleton (TASKS.md Phase 14.29). The calendar screen
/// reaches for [careEventsRepositoryProvider] and never sees the concrete
/// drift database — same indirection [careCircleRepositoryProvider] uses.
///
/// In production the repo opens its own [CareblazersDatabase] handle onto
/// the shared SQLite file; SQLite's per-connection serialization keeps
/// that safe. Tests build a [CareEventsRepository] directly against
/// `CareblazersDatabase(NativeDatabase.memory())` so each test gets an
/// isolated DB.
@Riverpod(keepAlive: true)
CareEventsRepository careEventsRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return CareEventsRepository(db);
}

/// Alias for consumers — matches the `careEventsRepositoryProvider` name
/// the calendar screen reaches for.
final CareEventsRepositoryBackendProvider careEventsRepositoryProvider =
    careEventsRepositoryBackendProvider;

/// Task-sourced calendar events ([CareEventKind.task]) — projects every
/// **standalone** task that carries a due time onto the shared calendar
/// (unified task/routine model, 2026-06-06).
///
/// Only standalone tasks (`routineId == null`) with a [CareTask.dueAt]
/// surface as loose blocks; a routine-bound task renders under its routine
/// header instead, so it's excluded here. Tests override this provider to
/// inject sample task events.
@riverpod
Future<List<CareEvent>> calendarTaskEvents(Ref ref) async {
  final CareTasksRepository repo = ref.watch(careTasksRepositoryProvider);
  // Scope to the active loved one (multi-patient, Issue #6) so the Schedule
  // calendar never surfaces another person's task blocks.
  final String patientId = await ref.watch(activePatientIdProvider.future);
  final List<CareTask> tasks = await repo.listTasksForPatient(patientId);
  return <CareEvent>[
    for (final CareTask task in tasks)
      if (task.routineId == null && task.dueAt != null)
        careEventFromTask(task),
  ];
}

/// Shift-sourced calendar events ([CareEventKind.shift]) — the seam Phase
/// 14.31 overrides to project Care Team → Shifts onto the shared calendar
/// (TASKS.md Phase 14.29). Empty until then; see [calendarTaskEvents] for
/// the rationale.
@riverpod
Future<List<CareEvent>> calendarShiftEvents(Ref ref) async =>
    const <CareEvent>[];

/// The unified shared-calendar event stream (TASKS.md Phase 14.29,
/// BUILD_SPEC.md §5.14).
///
/// Merges the four sources into one chronologically-sorted list:
/// 1. **Appointments** — projected from [appointmentRepositoryProvider]
///    via [careEventFromAppointment] (read-only; no double-storage).
/// 2. **Tasks** — from the [calendarTaskEvents] seam (Phase 14.30).
/// 3. **Shifts** — from the [calendarShiftEvents] seam (Phase 14.31).
/// 4. **Notes** — the natively-stored events from
///    [careEventsRepositoryProvider].
///
/// Tests override the two repository providers with in-memory repos and
/// the two source seams with sample lists, so the future resolves
/// synchronously inside the harness.
@riverpod
Future<List<CareEvent>> careEvents(Ref ref) async {
  final AppointmentRepository appointmentRepo =
      ref.watch(appointmentRepositoryProvider);
  final List<Appointment> appointments =
      await appointmentRepo.listAppointments();

  // Resolve provider names in one batch so each projected block carries a
  // readable title without a query per appointment. The loop var stays
  // inferred — naming the `Provider` model type here would collide with
  // riverpod's own `Provider`.
  final Map<String, String> providerNames = <String, String>{};
  for (final provider in await appointmentRepo.listProviders()) {
    providerNames[provider.id] = provider.name;
  }

  final List<CareEvent> events = <CareEvent>[
    for (final Appointment appointment in appointments)
      careEventFromAppointment(
        appointment,
        providerName: providerNames[appointment.providerId],
      ),
  ];

  // Notes are scoped to the active loved one (multi-patient, Issue #6); the
  // appointment / task / shift sources are scoped at their own seams (the
  // appointment projection FKs onto a provider, not a patient, so it isn't
  // filtered here).
  final String patientId = await ref.watch(activePatientIdProvider.future);
  final CareEventsRepository notesRepo =
      ref.watch(careEventsRepositoryProvider);
  events.addAll(await notesRepo.listEventsForPatient(patientId));

  events.addAll(await ref.watch(calendarTaskEventsProvider.future));
  events.addAll(await ref.watch(calendarShiftEventsProvider.future));

  events.sort((CareEvent a, CareEvent b) => a.start.compareTo(b.start));
  return events;
}

/// Wall clock the calendar samples to pick the initially-shown week.
/// Overridable so widget + golden tests pin a fixed "now" and the visible
/// week stays stable across host time — same pattern
/// [appointmentListClockProvider] uses.
@Riverpod(keepAlive: true)
DateTime Function() calendarClock(Ref ref) => DateTime.now;

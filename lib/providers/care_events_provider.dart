import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/appointment.dart';
import '../models/care_event.dart';
import '../services/appointment_repository.dart';

part 'care_events_provider.g.dart';

/// Logical patient id projected appointment events carry (TASKS.md Phase
/// 14.29). Appointments FK onto a provider, not a patient, so the
/// projection stamps the single-install loved one here — same fallback
/// constant the medical + care-circle forms use.
const String calendarPatientId = 'demo-patient-mary';

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
    patientId: calendarPatientId,
    externalRef: appointment.id,
  );
}

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
class CareEventsRepository {
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
  }

  /// Drop the event with this id. No-op if absent.
  Future<void> deleteEvent(String id) async {
    await (_db.delete(_db.careEventsTable)..where((t) => t.id.equals(id)))
        .go();
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

/// Task-sourced calendar events ([CareEventKind.task]) — the seam Phase
/// 14.30 overrides to project Care Team → Tasks onto the shared calendar
/// (TASKS.md Phase 14.29).
///
/// Contributes nothing until that phase lands; kept as an overridable
/// provider so the [careEvents] unifier can merge all four sources
/// without this phase pre-building the Tasks module. Tests override it to
/// inject sample task events.
@riverpod
Future<List<CareEvent>> calendarTaskEvents(Ref ref) async =>
    const <CareEvent>[];

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

  final CareEventsRepository notesRepo =
      ref.watch(careEventsRepositoryProvider);
  events.addAll(await notesRepo.listEvents());

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

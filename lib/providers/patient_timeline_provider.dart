import 'package:flutter_riverpod/flutter_riverpod.dart' show WidgetRef;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/appointment.dart';
import '../models/care_event.dart';
import '../models/care_plan_routine.dart';
import '../models/care_task.dart';
import '../models/health_log_entry.dart';
import '../models/journal_entry.dart';
import '../models/medication.dart';
import '../providers/active_patient_provider.dart';
import '../providers/care_events_provider.dart'
    show
        fallbackPatientId,
        careEventFromAppointment,
        careEventFromTask,
        calendarTaskEventsProvider;
import '../providers/care_plan_provider.dart';
import '../providers/care_tasks_provider.dart';
import '../providers/health_log_provider.dart';
import '../providers/journal_entries_provider.dart';
import '../services/appointment_repository.dart';
import '../screens/medication/dose_log_screen.dart' show dosesTodayProvider;
import '../services/medication_repository.dart'
    show MedicationRepository, ScheduledDose, medicationRepositoryProvider;
import '../widgets/home/catch_me_up_card.dart' show catchMeUpEventsProvider;

part 'patient_timeline_provider.g.dart';

// ---------------------------------------------------------------------------
// Projection helpers — turn each source domain object into a [CareEvent].
//
// These are pure display projections (no `ref`), so for sources that don't
// carry their own patientId (doses, journal entries) the event is stamped
// with [fallbackPatientId] as a stable fallback label. The patient-scoped
// *queries* that feed them — e.g. `repo.dosesInWindow` in
// [patientDoseEvents] — now follow the active patient via
// [activePatientIdProvider] (multi-patient, Issue #6); with one loved one
// on file that resolves to the sole id, so the projection label matches.
// ---------------------------------------------------------------------------

/// Project a [ScheduledDose] onto the unified timeline.
///
/// Returns a [CareEventKind.doseLogged] event when the dose has been
/// recorded (`scheduledDose.log != null`) and a [CareEventKind.doseScheduled]
/// event otherwise. The synthetic id encodes both the schedule id and the
/// wall-clock occurrence so a forecast block deep-links to the exact slot
/// in the dose log timeline; a logged block carries the dose-log row id
/// as [CareEvent.externalRef] so the dose-log screen can highlight it.
///
/// Block duration: the [Medication] doesn't carry a per-dose duration, so
/// forecast blocks render with no [CareEvent.end] (the calendar grid
/// falls back to a one-hour block via [CareEventX.blockDuration]).
CareEvent careEventFromScheduledDose(ScheduledDose dose) {
  final DoseLog? log = dose.log;
  final String medName = dose.medication.name;
  final String dosage = dose.medication.dosage;
  if (log != null) {
    final String verb = switch (log.status) {
      DoseStatus.skipped => 'Skipped',
      DoseStatus.missed => 'Missed',
      _ => 'Gave',
    };
    return CareEvent(
      id: 'dose-log-${log.id}',
      kind: CareEventKind.doseLogged,
      title: medName,
      // Activity-feed-style sentence — "Gave Donepezil 10 mg".
      subtitle: '$verb $medName $dosage',
      start: log.takenAt ?? dose.scheduledFor,
      patientId: fallbackPatientId,
      externalRef: log.id,
      windowLabel: dose.window.label,
      windowSlot: dose.scheduledFor,
    );
  }
  // Slot id encodes both the (window, entry) pair and the wall-clock
  // occurrence so a tapped block deep-links back to a specific instance
  // — pre-window the schedule id alone was enough.
  final String slotId = '${dose.window.id}:${dose.entry.id}@'
      '${dose.scheduledFor.toIso8601String()}';
  return CareEvent(
    id: 'dose-sched-$slotId',
    kind: CareEventKind.doseScheduled,
    title: medName,
    subtitle: '$medName $dosage',
    start: dose.scheduledFor,
    patientId: fallbackPatientId,
    externalRef: slotId,
    windowLabel: dose.window.label,
    windowSlot: dose.scheduledFor,
  );
}

/// Project a [HealthLogEntry] onto the timeline.
///
/// Title prefix matches the entry's kind — "Vitals", "Symptom", "Note" —
/// so a tapped chip's label is parseable at a glance. Wall-clock anchor
/// is the entry's [HealthLogEntry.recordedAt].
CareEvent careEventFromHealthLogEntry(HealthLogEntry entry) {
  final String prefix = switch (entry.kind) {
    HealthLogKind.vitals => 'Vitals',
    HealthLogKind.symptom => 'Symptom',
    HealthLogKind.note => 'Note',
  };
  // Subtitle prefers the caregiver's free-text notes for a textual
  // entry; falls back to the prefix label so a feed row never reads
  // bare. Vitals/symptom entries with structured fields could be
  // extended here once we want richer formatting in the activity feed.
  final String? notes = entry.notes?.trim();
  final String subtitle = (notes != null && notes.isNotEmpty)
      ? '$prefix — $notes'
      : prefix;
  return CareEvent(
    id: 'health-log-${entry.id}',
    kind: CareEventKind.healthLogEntry,
    title: prefix,
    subtitle: subtitle,
    start: entry.recordedAt,
    patientId: entry.patientId,
    externalRef: entry.id,
  );
}

/// Project a [JournalEntry] onto the timeline.
///
/// JournalEntry doesn't carry a patientId in v1 (single-patient), so the
/// projection uses [fallbackPatientId]. Title uses the behavior's label
/// so the chip reads "Repetitive questions" rather than the enum's
/// underscored name.
/// Project a [CarePlanRoutine] occurrence onto the timeline. Each
/// occurrence (a single wall-clock DateTime emitted by
/// [CarePlanRepository.expand]) becomes its own event so the calendar
/// can render a marker per slot. The synthetic id encodes routine + ISO
/// timestamp so a forecast occurrence stays stable across renders.
CareEvent careEventFromCarePlanRoutine(
  CarePlanRoutine routine,
  DateTime occurrence,
) {
  return CareEvent(
    id: 'care-plan-${routine.id}@'
        '${occurrence.toIso8601String()}',
    kind: CareEventKind.carePlanItem,
    title: routine.title,
    subtitle: routine.title,
    start: occurrence,
    patientId: routine.patientId,
    externalRef: routine.id,
  );
}

CareEvent careEventFromJournalEntry(JournalEntry entry) {
  // Wizard-authored entries surface the caregiver's situation text as
  // the activity feed sentence (matching the pre-unified
  // [recentActivityJournalSummary] behavior); decoder auto-logs fall
  // back to the behavior label.
  String subtitle = entry.behavior.label;
  if (entry.wizardKind) {
    final String? situation = entry.situationText?.trim();
    if (situation != null && situation.isNotEmpty) {
      subtitle = situation;
    } else {
      subtitle = 'Journal note';
    }
  }
  return CareEvent(
    id: 'journal-${entry.id}',
    kind: CareEventKind.journalEntry,
    title: entry.behavior.label,
    subtitle: subtitle,
    start: entry.createdAt,
    patientId: fallbackPatientId,
    externalRef: entry.id,
  );
}

// ---------------------------------------------------------------------------
// Projection providers — one per source, each returning a list of
// [CareEvent] ready for the merger.
// ---------------------------------------------------------------------------

/// How far ahead the patient-timeline forecast projects scheduled doses
/// and care-plan routines. The Schedule calendar's widest view (Upcoming)
/// spans the next 30 days, and its Day/Week views can page to any day in
/// that horizon, so the forecast has to cover the whole span — otherwise a
/// permanent med stops appearing partway through the window (alpha report
/// fb_1780960227608706: "Upcoming only goes one day past week"). Each
/// calendar view clips this source to its own visible window, so a
/// permanent med never renders past what's on screen.
const Duration _forecastHorizon = Duration(days: 30);

/// Scheduled doses across the forecast horizon projected onto the timeline.
///
/// Walks `[today - 1d, today + 30d]` so the Home Schedule card and the
/// Schedule calendar's Day / Week / Upcoming views all receive their dose
/// rows for any day they can show. The calendar clips this to each view's
/// visible window. Past occurrences carry their [DoseLog] when one exists
/// ([CareEventKind.doseLogged]); future occurrences carry no log
/// ([CareEventKind.doseScheduled]).
@riverpod
Future<List<CareEvent>> patientDoseEvents(Ref ref) async {
  // The wall-clock anchor for the forecast window. Reads via the
  // medication-repo wiring of [calendarClockProvider] would be cleaner
  // but the repo doesn't expose a clock seam; `DateTime.now()` is
  // overridable per-test by `MedicationRepository(clock:)` in the
  // backend provider, and that's the same path `dosesTodayProvider`
  // already takes — same source of "now" for both.
  final MedicationRepository repo =
      ref.watch(medicationRepositoryProvider);
  final String patientId = await ref.watch(activePatientIdProvider.future);
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime from = today.subtract(const Duration(days: 1));
  final DateTime to = today.add(_forecastHorizon);
  final List<ScheduledDose> doses =
      await repo.dosesInWindow(from, to, patientId: patientId);
  return <CareEvent>[
    for (final ScheduledDose dose in doses) careEventFromScheduledDose(dose),
  ];
}

/// All health-log entries for the patient, projected onto the timeline.
///
/// Reads from [healthLogProvider] (the AsyncNotifier owns the cache);
/// downstream consumers slice by wall-clock window themselves.
@riverpod
Future<List<CareEvent>> patientHealthLogEvents(Ref ref) async {
  final List<HealthLogEntry> entries =
      await ref.watch(healthLogProvider.future);
  return <CareEvent>[
    for (final HealthLogEntry entry in entries)
      careEventFromHealthLogEntry(entry),
  ];
}

/// All journal entries for the patient, projected onto the timeline.
///
/// Reads from [journalEntriesProvider] via `.future` so a decoder
/// auto-log or a wizard journal entry flows in without explicit
/// invalidation — same cadence the Home Recent Activity card uses.
/// Care plan routines expanded across the forecast horizon
/// (-1 day .. +30 days from the clock provider). Mirrors the
/// [patientDoseEvents] dose-expansion shape: each occurrence becomes a
/// `CareEventKind.carePlanItem` event the calendar can render. The
/// calendar clips this to each view's visible window.
@riverpod
Future<List<CareEvent>> patientCarePlanEvents(Ref ref) async {
  final List<CarePlanRoutine> routines =
      await ref.watch(carePlanProvider.future);
  if (routines.isEmpty) return const <CareEvent>[];
  final CarePlanRepository repo = ref.watch(carePlanRepositoryProvider);
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime from = today.subtract(const Duration(days: 1));
  final DateTime to = today.add(_forecastHorizon);
  return <CareEvent>[
    for (final CarePlanRoutine routine in routines)
      for (final DateTime occurrence in repo.expand(routine, from, to))
        careEventFromCarePlanRoutine(routine, occurrence),
  ];
}

@riverpod
Future<List<CareEvent>> patientJournalEvents(Ref ref) async {
  final List<JournalEntry> entries =
      await ref.watch(journalEntriesProvider.future);
  return <CareEvent>[
    for (final JournalEntry entry in entries) careEventFromJournalEntry(entry),
  ];
}

/// Standalone tasks projected onto the patient timeline (unified
/// task/routine model, 2026-06-06).
///
/// A task is the atom and a routine is the bundle: only standalone tasks
/// (`routineId == null`) that carry a due time ride the schedule on their
/// own. Routine-bound tasks render under their routine, so they're
/// excluded here. Mirrors [calendarTaskEvents] — same filter, same
/// projection helper — so a loose task looks identical on Home's Today
/// schedule and the Schedule calendar.
@riverpod
Future<List<CareEvent>> patientTaskEvents(Ref ref) async {
  final CareTasksRepository repo = ref.watch(careTasksRepositoryProvider);
  final List<CareTask> tasks = await repo.listTasks();
  return <CareEvent>[
    for (final CareTask task in tasks)
      if (task.routineId == null && task.dueAt != null)
        careEventFromTask(task),
  ];
}

// ---------------------------------------------------------------------------
// Patient timeline merger — single source of truth for "what's happening
// today (and recently)" views.
// ---------------------------------------------------------------------------

/// The unified patient timeline (the Recent Activity card, the Med
/// Schedule screen, and any future "Today" timeline view all read this).
///
/// Merges five patient-scoped sources into one chronologically-sorted
/// list (ascending by [CareEvent.start]):
/// 1. **Appointments** — projected from [appointmentRepositoryProvider]
///    via [careEventFromAppointment] (the same helper the Team Calendar
///    uses; the appointment kind is in BOTH the team and patient
///    audiences per [CareEventX.isPatientScoped]).
/// 2. **Today's doses** — from [patientDoseEvents]; each dose is either
///    [CareEventKind.doseScheduled] (forecast) or [CareEventKind.doseLogged]
///    (history) depending on whether the caregiver has acted on it.
/// 3. **Health log entries** — from [patientHealthLogEvents].
/// 4. **Journal entries** — from [patientJournalEvents].
///
/// Downstream views slice this list by a wall-clock window themselves
/// (e.g. "today only", "next 24h", "last 7 days") rather than this
/// provider exposing a family-keyed window — keeps the cache simple and
/// matches the [careEvents] convention.
///
/// Tests override each source via the existing per-source providers,
/// then read this merger to assert the merged ordering.
/// Invalidates every cached provider that reads any time-keyed source
/// the Home dashboard surfaces — `dosesTodayProvider`,
/// `patientTimelineEventsProvider` (which the Schedule card reads), and
/// `catchMeUpEventsProvider`.
///
/// Call this from mutation handlers (appointment / medication / health-log
/// / journal save / delete) so the next read picks up the change without
/// requiring an app restart. Cascading via `ref.watch` doesn't cover
/// these because the patient-timeline merger and `catchMeUpEventsProvider`
/// both call `repo.listAppointments()` directly on the appointment
/// repository — they share the repo's underlying DB with the writer but
/// cache the snapshot at watch time; only explicit invalidation re-runs
/// the query.
///
/// Per-form invalidations of source-specific providers (e.g.
/// `appointmentListProvider`, `medicationListProvider`) stay where they
/// are — this helper is purely additive, covering the dashboard surfaces
/// the writer screens don't otherwise know about.
void invalidatePatientTimeline(WidgetRef ref) {
  ref.invalidate(patientDoseEventsProvider);
  ref.invalidate(patientTimelineEventsProvider);
  ref.invalidate(catchMeUpEventsProvider);
  // Standalone tasks ride the schedule too (unified task/routine model);
  // invalidate both their patient-timeline + calendar projections so a
  // newly-added or reconciled task shows on Home + the Schedule calendar.
  ref.invalidate(patientTaskEventsProvider);
  ref.invalidate(calendarTaskEventsProvider);
  // The "Today's doses" screen + the Home "Medications today" card read
  // this directly; Home keeps it alive across tab switches, so without an
  // explicit invalidate a newly-added med never appears there (alpha bug
  // report: "Medication not showing up in today's doses").
  ref.invalidate(dosesTodayProvider);
}

@riverpod
Future<List<CareEvent>> patientTimelineEvents(Ref ref) async {
  // Appointments: project via the same helper the Team Calendar uses so
  // the appointment block looks identical in both audiences.
  final AppointmentRepository appointmentRepo =
      ref.watch(appointmentRepositoryProvider);
  final List<Appointment> appointments =
      await appointmentRepo.listAppointments();
  final Map<String, String> providerNames = <String, String>{};
  for (final provider in await appointmentRepo.listProviders()) {
    providerNames[provider.id] = provider.name;
  }
  final List<CareEvent> events = <CareEvent>[
    for (final Appointment appt in appointments)
      careEventFromAppointment(
        appt,
        providerName: providerNames[appt.providerId],
      ),
  ];

  // The three new patient-scoped sources.
  events.addAll(await ref.watch(patientDoseEventsProvider.future));
  events.addAll(await ref.watch(patientHealthLogEventsProvider.future));
  events.addAll(await ref.watch(patientJournalEventsProvider.future));
  events.addAll(await ref.watch(patientCarePlanEventsProvider.future));
  events.addAll(await ref.watch(patientTaskEventsProvider.future));

  events.sort((CareEvent a, CareEvent b) => a.start.compareTo(b.start));
  return events;
}

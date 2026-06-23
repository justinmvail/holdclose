import 'package:freezed_annotation/freezed_annotation.dart';

part 'care_event.freezed.dart';
part 'care_event.g.dart';

/// What kind of thing a [CareEvent] represents on the shared calendar
/// (TASKS.md Phase 14.29, BUILD_SPEC.md §5.14).
///
/// The calendar unifies four sources into one event stream. Three of them
/// are **projections** of data that already lives elsewhere — the
/// calendar never double-stores them:
/// - [appointment] — projected from the appointment tracker (Phase 12.6),
///   read-only on the calendar.
/// - [task] — projected from Care Team → Tasks (Phase 14.30).
/// - [shift] — projected from Care Team → Shifts (Phase 14.31).
///
/// The fourth, [note], is the only kind that lives **natively** in the
/// `care_events` table — an ad-hoc jotting the caregiver adds straight on
/// the calendar with no other home.
///
/// One token per value so the JSON name matches the enum name exactly
/// (`json_serializable` serialises enums by `.name`; the drift column
/// persists that `.name` inside the payload blob).
enum CareEventKind {
  // Team-scoped (the Care Team Calendar reads these).
  appointment,
  task,
  shift,
  note,
  // Patient-scoped (the unified patient timeline reads these +
  // appointment). Projected from the medication, health-log, and
  // journal data layers — never double-stored.
  // - [doseScheduled] — an upcoming dose from a [DoseSchedule]
  //   (forecast). `externalRef` is `<scheduleId>@<isoTime>` so a
  //   tapped block opens that specific dose slot.
  // - [doseLogged] — a recorded dose from [DoseLogs] (history).
  //   `externalRef` is the dose-log row id; the block's status comes
  //   from the log's `outcome` (taken/late/skipped/missed).
  // - [healthLogEntry] — a vitals/symptom/note entry from
  //   [HealthLogEntriesTable]. `externalRef` is the entry id.
  // - [journalEntry] — a caregiver-authored journal note from
  //   [JournalEntriesTable]. `externalRef` is the entry id.
  doseScheduled,
  doseLogged,
  healthLogEntry,
  journalEntry,
  // A scheduled occurrence of a [CarePlanRoutine] (BUILD_SPEC.md §5.13
  // v2). `externalRef` is the routine id; tapping a block opens the
  // routine edit form.
  carePlanItem,
}

/// One thing on the Care Team shared calendar (TASKS.md Phase 14.29,
/// BUILD_SPEC.md §5.14).
///
/// A single shape the week-view grid renders regardless of where the
/// event came from. [start] is required; [end] is optional (a bare
/// reminder-style note may have no duration — the grid gives those a
/// default-height block). [ownerCaregiverId] links the event to whoever
/// it belongs to (the assigned task-doer, the shift-coverer); null for an
/// unassigned event. [patientId] is a logical link to the single-row
/// patients table (carried explicitly so a future multi-patient model
/// lands without a migration, mirroring the health-log + care-circle
/// models). [externalRef] is the id of the source row this event projects
/// from — the appointment / task / shift id a tapped block routes to;
/// null for a native [CareEventKind.note], which has no separate detail
/// page.
@freezed
abstract class CareEvent with _$CareEvent {
  const factory CareEvent({
    required String id,
    required CareEventKind kind,
    required String title,
    required DateTime start,
    DateTime? end,
    String? ownerCaregiverId,
    required String patientId,
    String? externalRef,
    // Pre-formatted rich text for "activity feed"-style consumers
    // (Home Recent Activity, future Today timeline). The week-view
    // Calendar reads only [title] so its blocks stay short; the
    // activity feed reads [subtitle] when non-null and falls back to
    // [title] when not. Projection helpers populate it with the
    // kind-appropriate sentence ("Gave Donepezil 10 mg",
    // "Appointment with Dr. Ortega", a journal's situation text). The
    // four team-scoped kinds leave it null today; native [note] events
    // can store it directly in the `care_events` drift table.
    String? subtitle,
    // For dose events ([CareEventKind.doseScheduled] /
    // [CareEventKind.doseLogged]) — the label of the [DoseWindow] the
    // dose belongs to ("Morning", "Evening"). Window-grouped consumers
    // (the Home Schedule card) head a dose group with the window name +
    // time rather than a bare clock minute. Null for every other kind
    // and for any dose that predates window scheduling.
    String? windowLabel,
    // For dose events — the window's canonical occurrence for the day
    // (the anchored slot, [ScheduledDose.scheduledFor]). Distinct from
    // [start], which for a logged dose is when the caregiver actually
    // gave it: a dose given at 2:15pm still belongs to the 8:00am
    // "Morning" slot. Window-grouped consumers display + order by this
    // so a late-logged dose stays under its window's time. Null for
    // every non-dose kind.
    DateTime? windowSlot,
  }) = _CareEvent;

  factory CareEvent.fromJson(Map<String, dynamic> json) =>
      _$CareEventFromJson(json);
}

/// Routing + duration helpers for [CareEvent], kept off the freezed
/// factory so the generated model stays a pure data class.
extension CareEventX on CareEvent {
  /// Where a tapped block navigates — the source row's detail page
  /// (BUILD_SPEC.md §5.14 "Tap a block routes to the source detail").
  ///
  /// Derived from [CareEvent.kind] + [CareEvent.externalRef]:
  /// - [CareEventKind.appointment] → `/appointments/<ref>` (Phase 12.6).
  /// - [CareEventKind.task] → `/team/tasks` (the task list; no per-id page).
  /// - [CareEventKind.shift] → `/team/shifts/<ref>` (Phase 14.31).
  /// - [CareEventKind.note] → null; a note lives natively on the calendar
  ///   and has no separate detail page.
  ///
  /// Null whenever [externalRef] is null (a projection with a missing
  /// source id is non-tappable rather than routing nowhere).
  String? get detailRoute {
    final String? ref = externalRef;
    if (ref == null) return null;
    switch (kind) {
      case CareEventKind.appointment:
        return '/appointments/$ref';
      case CareEventKind.task:
        // Tasks have no per-id detail page; a tapped block opens the task
        // list (there is no `/team/tasks/:id` route — the old `$ref` form
        // dead-ended on "Page Not Found").
        return '/team/tasks';
      case CareEventKind.shift:
        return '/team/shifts/$ref';
      case CareEventKind.note:
        return null;
      case CareEventKind.doseScheduled:
      case CareEventKind.doseLogged:
        // Both routes resolve to the dose log timeline for the dose's
        // medication. Forecast blocks deep-link to the slot via
        // `externalRef = <scheduleId>@<isoTime>`; logged blocks carry
        // the dose-log id and the dose-log screen highlights the row.
        return '/medications/today';
      case CareEventKind.healthLogEntry:
        // Health-log entries have no standalone detail page — the list
        // opens an entry straight into its edit form, and there is no
        // `health-log/:id` route (only `:id/edit`). Match that so a
        // timeline tap doesn't dead-end on "Page Not Found".
        return '/medical/health-log/$ref/edit';
      case CareEventKind.journalEntry:
        return '/journal/$ref';
      case CareEventKind.carePlanItem:
        return '/medical/routines/$ref';
    }
  }

  /// True if this event participates in the patient timeline (Home
  /// Recent Activity, Med Schedule, the unified Today view).
  /// Appointment events are in both audiences so they show on both
  /// the Team Calendar AND the patient timeline.
  bool get isPatientScoped {
    switch (kind) {
      case CareEventKind.appointment:
      case CareEventKind.doseScheduled:
      case CareEventKind.doseLogged:
      case CareEventKind.healthLogEntry:
      case CareEventKind.journalEntry:
      case CareEventKind.carePlanItem:
        return true;
      case CareEventKind.task:
      case CareEventKind.shift:
      case CareEventKind.note:
        return false;
    }
  }

  /// True if this event participates in the Team Calendar.
  /// Appointment events are in both audiences so they show on both.
  bool get isTeamScoped {
    switch (kind) {
      case CareEventKind.appointment:
      case CareEventKind.task:
      case CareEventKind.shift:
      case CareEventKind.note:
        return true;
      case CareEventKind.doseScheduled:
      case CareEventKind.doseLogged:
      case CareEventKind.healthLogEntry:
      case CareEventKind.journalEntry:
      case CareEventKind.carePlanItem:
        return false;
    }
  }

  /// The block's vertical extent in the week grid. Falls back to one hour
  /// when the event carries no [CareEvent.end] (e.g. a reminder-style
  /// note) so every block stays tappable. Never negative — an [end]
  /// before [start] collapses to the one-hour default.
  Duration get blockDuration {
    final DateTime? e = end;
    if (e == null) return const Duration(hours: 1);
    final Duration d = e.difference(start);
    return d <= Duration.zero ? const Duration(hours: 1) : d;
  }
}

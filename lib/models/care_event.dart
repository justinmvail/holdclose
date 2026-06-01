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
  appointment,
  task,
  shift,
  note,
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
  /// - [CareEventKind.task] → `/team/tasks/<ref>` (Phase 14.30).
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
        return '/team/tasks/$ref';
      case CareEventKind.shift:
        return '/team/shifts/$ref';
      case CareEventKind.note:
        return null;
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

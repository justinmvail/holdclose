import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'medication.freezed.dart';
part 'medication.g.dart';

/// How often a recurring item fires (medication window entries, care
/// plan routines). Preserved from the legacy `DoseSchedule` model
/// because [CarePlanRoutine] and the notifications layer still drive
/// off daily / weekly / as-needed selection. The medication tracker
/// itself no longer carries a [FrequencyKind] — scheduling pivoted to
/// per-window time slots — but this enum stays in the medication model
/// file so the import graph doesn't fan out.
enum FrequencyKind {
  daily,
  twiceDaily,
  weekly,
  asNeeded,
}

/// Route of administration for a [Medication] (TASKS.md Phase 12.1).
///
/// Free-text routes the caregiver may need (e.g. "subcutaneous",
/// "patch") collapse onto [other] in v1 — the add-med form (Phase 12.3)
/// pairs the dropdown with a free-text "notes" field on the parent
/// [Medication] so an unusual route can still be captured.
enum MedicationRoute {
  oral,
  topical,
  injection,
  other,
}

/// Status of a logged dose (TASKS.md Phase 12.1).
///
/// [taken] — caregiver checked the dose off on time.
/// [missed] — the dose's scheduled window passed without a check-off.
/// [skipped] — caregiver explicitly chose not to give the dose
///   (e.g. patient asleep, vomiting). Distinct from [missed] so the
///   adherence-rate helper can separate "we missed it" from "we
///   deliberately held it".
/// [late] — caregiver checked the dose off after the scheduled window
///   closed. Surfaced with a small badge in the dose-log UI.
enum DoseStatus {
  taken,
  missed,
  skipped,
  late,
}

/// JSON serializer for Flutter's [TimeOfDay] (TASKS.md Phase 12.1).
///
/// Serializes to a zero-padded 24-hour `HH:mm` string so the rendered
/// blob stays human-readable in sqlite + survives a parse from outside
/// Dart (the doctor-visit PDF export reads window times straight from
/// the JSON).
class TimeOfDayJsonConverter implements JsonConverter<TimeOfDay, String> {
  const TimeOfDayJsonConverter();

  @override
  TimeOfDay fromJson(String json) {
    final List<String> parts = json.split(':');
    return TimeOfDay(
      hour: int.parse(parts[0]),
      minute: int.parse(parts[1]),
    );
  }

  @override
  String toJson(TimeOfDay value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

/// Nullable variant for [DoseWindow.anchorTime] — an "as needed"
/// window has no anchor (it never expands into scheduled doses).
class NullableTimeOfDayJsonConverter
    implements JsonConverter<TimeOfDay?, String?> {
  const NullableTimeOfDayJsonConverter();

  @override
  TimeOfDay? fromJson(String? json) {
    if (json == null || json.isEmpty) return null;
    return const TimeOfDayJsonConverter().fromJson(json);
  }

  @override
  String? toJson(TimeOfDay? value) {
    if (value == null) return null;
    return const TimeOfDayJsonConverter().toJson(value);
  }
}

/// One tracked medication.
///
/// The structured counterpart to `CrisisMedication` (the free-text med
/// entry on the crisis card). Carries the id every
/// [MedicationWindowEntry] and [DoseLog] FKs onto. Soft-deleted via
/// [deletedAt] — the row stays on disk so dose history survives an
/// accidental delete + powers an undo.
///
/// **Scheduling is window-driven, not per-medication.** A medication
/// doesn't own clock times any more; it gets linked to one or more
/// [DoseWindow]s via [MedicationWindowEntry]. That matches how
/// caregivers actually think — "what does Mom take in the morning?"
/// rather than "when does she take Donepezil?" — and how physical
/// pillboxes are organised.
@freezed
abstract class Medication with _$Medication {
  const factory Medication({
    required String id,
    required String name,

    /// Free-text dosage as the caregiver wrote it on the bottle —
    /// "10 mg", "1 tablet", "5 mL". Stored verbatim so transcription
    /// errors trace back to the source. The medication form composes
    /// this from an amount field + a unit dropdown.
    required String dosage,
    required MedicationRoute route,

    /// Prescribing clinician (free text). Optional — over-the-counter
    /// entries leave it empty.
    String? prescriber,

    /// Free-text notes the caregiver wants to keep visible on the med
    /// card (e.g. "take with food", "watch for drowsiness").
    String? notes,

    /// --- Prescription-label details (optional; populated by the AI label
    /// scan or entered by hand). All free-text/verbatim so a transcription
    /// traces back to the printed label, and all nullable so older rows +
    /// manual entries simply leave them empty. Stored in the same JSON
    /// payload as the rest of the model — no schema migration. ---

    /// Rx (prescription) number printed on the label — needed to phone in
    /// a refill.
    String? rxNumber,

    /// Quantity dispensed, as printed ("180", "30 tablets").
    String? quantity,

    /// Refills remaining, as printed ("3", "0", "3 by 5/27/22").
    String? refills,

    /// Dispensing pharmacy name ("CVS Pharmacy").
    String? pharmacyName,

    /// Dispensing pharmacy phone — for refill calls.
    String? pharmacyPhone,

    /// Date the prescription was filled, verbatim as printed.
    String? dateFilled,

    /// "Discard after" / use-by date, verbatim as printed.
    String? discardAfter,

    /// Soft-delete tombstone. Null for a live medication; set to the
    /// deletion instant when the caregiver removes it. The repository
    /// excludes tombstoned rows from every derived view.
    DateTime? deletedAt,

    /// Optional end date — when set and in the past relative to the
    /// repository's wall clock, the medication is treated as ended:
    /// dropped from [MedicationRepository.listMedications], no further
    /// doses projected onto the timeline. Useful for short courses
    /// (antibiotics, taper plans) the caregiver wants to forget once
    /// the prescription runs out. The row stays on disk so dose
    /// history survives + the caregiver can clear `endsAt` to re-open.
    DateTime? endsAt,
  }) = _Medication;

  factory Medication.fromJson(Map<String, dynamic> json) =>
      _$MedicationFromJson(json);
}

/// One time-of-day "window" for a patient's medications.
///
/// Pillbox-style mental model: Morning / Noon / Evening / Bedtime are
/// the seeded windows, each anchored to a wall-clock time the
/// caregiver can edit. Medications join a window via
/// [MedicationWindowEntry]; the timeline projection expands a window
/// into one occurrence per day at [anchorTime], one occurrence per
/// medication in the window.
///
/// [anchorTime] is **nullable** so the seeded "As needed" window can
/// exist as a real row without ever expanding into the schedule —
/// caregivers log as-needed doses ad-hoc.
@freezed
abstract class DoseWindow with _$DoseWindow {
  const factory DoseWindow({
    required String id,
    required String patientId,
    required String label,

    /// Wall-clock anchor for the window. Null means "as needed" — the
    /// window holds a list of meds but never expands into scheduled
    /// occurrences.
    @NullableTimeOfDayJsonConverter() TimeOfDay? anchorTime,

    /// Display order in the windows list (0 = first). Seeded windows
    /// land at 0–4; user-added windows append.
    required int sortOrder,
  }) = _DoseWindow;

  factory DoseWindow.fromJson(Map<String, dynamic> json) =>
      _$DoseWindowFromJson(json);
}

extension DoseWindowX on DoseWindow {
  /// True when this window has no clock anchor — its meds never expand
  /// into scheduled occurrences.
  bool get isAsNeeded => anchorTime == null;
}

/// The membership of a [Medication] in a [DoseWindow].
///
/// One row per (medication, window) pair. A medication that takes the
/// same dose at multiple windows (e.g. Tylenol morning + bedtime) gets
/// two entries. [daysOfWeek] gates which weekdays the entry expands on
/// — empty = every day; populated = only those days
/// (`DateTime.weekday` convention: Monday = 1, Sunday = 7).
/// [startsOn]/[endsOn] bound the entry's active range; an open-ended
/// med leaves [endsOn] null.
@freezed
abstract class MedicationWindowEntry with _$MedicationWindowEntry {
  const factory MedicationWindowEntry({
    required String id,
    required String medicationId,
    required String windowId,
    required Set<int> daysOfWeek,
    required DateTime startsOn,
    DateTime? endsOn,
  }) = _MedicationWindowEntry;

  factory MedicationWindowEntry.fromJson(Map<String, dynamic> json) =>
      _$MedicationWindowEntryFromJson(json);
}

/// One logged dose event.
///
/// The dose-log UI flips [status] between [DoseStatus] values and
/// stamps [takenAt] when the caregiver acts. [scheduledFor] keys the
/// row to a specific occurrence (the wall-clock the window-anchor
/// expansion produced); ad-hoc as-needed doses use the caregiver's
/// stamp time for both.
///
/// FK on [medicationId] cascades on delete — wiping a medication wipes
/// its history.
@freezed
abstract class DoseLog with _$DoseLog {
  const factory DoseLog({
    required String id,
    required String medicationId,
    required DateTime scheduledFor,
    DateTime? takenAt,
    required DoseStatus status,
    String? notes,
  }) = _DoseLog;

  factory DoseLog.fromJson(Map<String, dynamic> json) =>
      _$DoseLogFromJson(json);
}

import 'package:freezed_annotation/freezed_annotation.dart';

part 'health_log_entry.freezed.dart';
part 'health_log_entry.g.dart';

/// What a single [HealthLogEntry] records (TASKS.md Phase 14.16).
///
/// [vitals] — a structured measurement: blood pressure ([systolic] /
///   [diastolic]), [heartRate], [temperatureF], or any combination the
///   caregiver took in one sitting.
/// [symptom] — an observed symptom the caregiver wants to track over
///   time, optionally rated 1–5 via [HealthLogEntry.severity].
/// [note] — a free-text observation that doesn't fit either bucket.
///
/// The kind drives how the Health Log screen (a later Phase 14 task)
/// renders the row and which fields the add form surfaces; the model
/// itself leaves every measurement field nullable so a `note` row can
/// omit them entirely.
enum HealthLogKind {
  vitals,
  symptom,
  note,
}

/// One health-log row for the loved one (TASKS.md Phase 14.16).
///
/// Lives under Medical → Health Log (BUILD_SPEC.md §5.13). A wellness
/// record, not a clinical one — the caregiver jots vitals, symptoms, and
/// notes here to bring the real picture to a doctor visit; nothing in
/// this model diagnoses or prescribes.
///
/// Every measurement field is nullable so each [kind] only fills what it
/// needs: a [HealthLogKind.vitals] row carries [systolic] / [diastolic]
/// / [heartRate] / [temperatureF] / [glucoseMgDl]; a
/// [HealthLogKind.symptom] row carries
/// [severity] (1–5) + [notes]; a [HealthLogKind.note] row carries just
/// [notes]. The model does not enforce which fields go with which kind —
/// that's the add-form's job — so an unusual combination still round-
/// trips cleanly.
///
/// [patientId] FKs (logically — see `lib/db/tables.dart` for why no DB
/// FK) onto the single loved one the install is configured for; it's
/// carried explicitly so the `byPatient` selector survives a future
/// multi-patient model without a migration.
@freezed
abstract class HealthLogEntry with _$HealthLogEntry {
  const factory HealthLogEntry({
    required String id,
    required String patientId,
    required DateTime recordedAt,
    required HealthLogKind kind,

    /// Symptom severity, 1 (mild) – 5 (severe). Null for vitals + note
    /// rows, and for a symptom the caregiver didn't rate.
    int? severity,

    /// Systolic / diastolic blood pressure (mmHg). Both null unless the
    /// caregiver logged a BP reading.
    int? systolic,
    int? diastolic,

    /// Heart rate (beats per minute). Null when not measured.
    int? heartRate,

    /// Body temperature in degrees Fahrenheit. Null when not measured.
    double? temperatureF,

    /// Blood glucose (mg/dL). Null when not measured.
    int? glucoseMgDl,

    /// Free-text observation. The whole payload for a [HealthLogKind.note]
    /// row; an optional annotation on vitals + symptom rows.
    String? notes,
  }) = _HealthLogEntry;

  factory HealthLogEntry.fromJson(Map<String, dynamic> json) =>
      _$HealthLogEntryFromJson(json);
}

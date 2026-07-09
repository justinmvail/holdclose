import 'package:freezed_annotation/freezed_annotation.dart';

part 'patient.freezed.dart';
part 'patient.g.dart';

/// One free-text medication entry on the crisis card
/// (BUILD_SPEC.md §5.9 + §9.1). A snapshot for paramedic / ER handoff —
/// distinct from the structured tracker [Medication] (Phase 12.1) in
/// `lib/models/medication.dart`, which carries id + schedule + dose log.
@freezed
abstract class CrisisMedication with _$CrisisMedication {
  const factory CrisisMedication({
    required String name,
    required String dose,
    required String schedule,
  }) = _CrisisMedication;

  factory CrisisMedication.fromJson(Map<String, dynamic> json) =>
      _$CrisisMedicationFromJson(json);
}

/// A named contact with a phone number (primary caregiver, POA, etc.)
/// shown on the crisis card (BUILD_SPEC.md §5.9 + §9.1).
@freezed
abstract class Contact with _$Contact {
  const factory Contact({
    required String name,
    required String phone,
  }) = _Contact;

  factory Contact.fromJson(Map<String, dynamic> json) =>
      _$ContactFromJson(json);
}

/// Advance directive on-file status (BUILD_SPEC.md §5.9 + §9.1).
@freezed
abstract class AdvanceDirectiveStatus with _$AdvanceDirectiveStatus {
  const factory AdvanceDirectiveStatus({
    required String onFileAt,
    required bool dnr,
  }) = _AdvanceDirectiveStatus;

  factory AdvanceDirectiveStatus.fromJson(Map<String, dynamic> json) =>
      _$AdvanceDirectiveStatusFromJson(json);
}

/// The single "loved one" the caregiver is using the app for
/// (BUILD_SPEC.md §5.9 + §9.1). One row per install — single-patient
/// model in v1.
@freezed
abstract class Patient with _$Patient {
  const factory Patient({
    required String id,
    required String name,
    required int age,

    /// Optional — EMS/clinicians expect a date of birth, but the setup
    /// wizard only requires a name, so profiles saved with age alone (or
    /// before this field existed — the patients table persists the model
    /// as a JSON blob, so old rows deserialize with null here) carry only
    /// the stored [age].
    DateTime? dateOfBirth,
    required String diagnosis,
    required DateTime diagnosedAt,
    required List<CrisisMedication> medications,
    required List<String> allergies,
    required List<String> calms,
    required List<String> escalates,
    required Contact primaryCaregiver,
    required Contact healthcarePOA,
    required AdvanceDirectiveStatus advanceDirective,
  }) = _Patient;

  factory Patient.fromJson(Map<String, dynamic> json) =>
      _$PatientFromJson(json);
}

/// Whole years between [dateOfBirth] and [asOf] — calendar-aware (the
/// count is one lower until the birthday has passed in [asOf]'s year).
/// Clamped at 0 so a future-dated birth date can't render a negative age.
int ageFromDateOfBirth(DateTime dateOfBirth, DateTime asOf) {
  int years = asOf.year - dateOfBirth.year;
  final bool beforeBirthday = asOf.month < dateOfBirth.month ||
      (asOf.month == dateOfBirth.month && asOf.day < dateOfBirth.day);
  if (beforeBirthday) years--;
  return years < 0 ? 0 : years;
}

/// Age helpers for [Patient], kept off the freezed factory so the
/// generated model stays a pure data class.
extension PatientX on Patient {
  /// Age as of [asOf]: derived from [Patient.dateOfBirth] when it's on
  /// file, otherwise the stored [Patient.age]. [asOf] is explicit (no
  /// `DateTime.now()` default) so display code pins it via a clock
  /// provider and goldens stay deterministic.
  int ageOn(DateTime asOf) {
    final DateTime? dob = dateOfBirth;
    if (dob == null) return age;
    return ageFromDateOfBirth(dob, asOf);
  }
}

import 'package:freezed_annotation/freezed_annotation.dart';

part 'patient.freezed.dart';
part 'patient.g.dart';

/// One scheduled medication entry on the crisis card
/// (BUILD_SPEC.md §5.9 + §9.1).
@freezed
abstract class Medication with _$Medication {
  const factory Medication({
    required String name,
    required String dose,
    required String schedule,
  }) = _Medication;

  factory Medication.fromJson(Map<String, dynamic> json) =>
      _$MedicationFromJson(json);
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
    required String diagnosis,
    required DateTime diagnosedAt,
    required List<Medication> medications,
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

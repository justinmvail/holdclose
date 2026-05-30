import 'package:freezed_annotation/freezed_annotation.dart';

part 'appointment.freezed.dart';
part 'appointment.g.dart';

/// Role of a healthcare [Provider] the caregiver coordinates with
/// (TASKS.md Phase 12.5).
///
/// Free-text roles the caregiver may need ("home health aide", "physical
/// therapist") collapse onto [other] in v1 — the add-provider form
/// (Phase 12.7) pairs the dropdown with the parent [Provider]'s
/// free-text [Provider.notes] field so an unusual role can still be
/// captured. [socialWorker] is one token so the JSON name matches the
/// dropdown label exactly.
enum ProviderRole {
  doctor,
  neurologist,
  socialWorker,
  other,
}

/// Lifecycle state of an [Appointment] (TASKS.md Phase 12.5).
///
/// [upcoming] — scheduled, not yet started. The list screen (Phase 12.6)
///   groups these under "Upcoming".
/// [completed] — visit happened. The detail screen (Phase 12.6) keeps
///   the agenda + post-visit notes editable so the caregiver can keep
///   filling them in afterward.
/// [canceled] — appointment fell through. Stays in the "Past" group so
///   the caregiver can see what was on the books without re-creating
///   the row.
enum AppointmentStatus {
  upcoming,
  completed,
  canceled,
}

/// One healthcare provider the caregiver coordinates with (TASKS.md
/// Phase 12.5).
///
/// Distinct from the free-text crisis-card contacts on [Patient] — this
/// row carries the id every [Appointment] FKs onto. Deleting a
/// [Provider] cascades through its appointments (drift FK action wired
/// in `lib/db/database.dart`).
///
/// [phone] and [address] are required so the appointment-detail screen
/// (Phase 12.6) can always wire the call + directions buttons; the
/// caregiver passes an empty string when a field is genuinely unknown.
/// [notes] is the catch-all for the things the form can't structure
/// (specialty, parking, "use side entrance").
@freezed
abstract class Provider with _$Provider {
  const factory Provider({
    required String id,
    required String name,
    required ProviderRole role,
    required String phone,
    required String address,
    String? notes,
  }) = _Provider;

  factory Provider.fromJson(Map<String, dynamic> json) =>
      _$ProviderFromJson(json);
}

/// One scheduled (or past) visit with a [Provider] (TASKS.md Phase
/// 12.5).
///
/// [location] is free text and may differ from [Provider.address] —
/// home visits, telehealth links, hospital wings on the day of the
/// visit all live here. [agenda] is the bullet list the caregiver
/// preps before the visit and crosses off in the waiting room (Phase
/// 12.6 renders each as a checkbox); empty list is fine for an as-yet-
/// unplanned visit. [notes] is the post-appointment debrief and stays
/// null until the caregiver fills it in.
///
/// FK on [providerId] cascades on delete — wiping a provider wipes its
/// appointment history alongside it.
@freezed
abstract class Appointment with _$Appointment {
  const factory Appointment({
    required String id,
    required String providerId,
    required DateTime startsAt,
    required int durationMinutes,
    required String location,
    required List<String> agenda,
    required AppointmentStatus status,
    String? notes,
  }) = _Appointment;

  factory Appointment.fromJson(Map<String, dynamic> json) =>
      _$AppointmentFromJson(json);
}

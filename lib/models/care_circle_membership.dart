import 'package:freezed_annotation/freezed_annotation.dart';

part 'care_circle_membership.freezed.dart';
part 'care_circle_membership.g.dart';

/// What a care-circle member is allowed to do (TASKS.md Phase 14.25).
///
/// [owner] manages the circle (invite / remove / change permissions),
/// [editor] can change care data (meds, appointments, tasks), and
/// [viewer] has read-only access. An app-level authorization tag the
/// circle owner assigns — not a clinical or legal role.
///
/// One token per value so the JSON name matches the enum name exactly
/// (`json_serializable` serialises enums by `.name`; the drift column
/// persists that `.name`).
enum PermissionLevel {
  owner,
  editor,
  viewer,
}

/// One caregiver's membership in a loved one's care circle (TASKS.md
/// Phase 14.25, BUILD_SPEC.md §5.14).
///
/// Joins a [Caregiver] (via [caregiverId]) to the loved one (via
/// [patientId]) with a [permissionLevel] and the invite lifecycle:
/// [invitedAt] is set when the invite is created, and [acceptedAt] flips
/// from null to a timestamp when the caregiver accepts. A null
/// [acceptedAt] means the invite is still **pending** — the roster badges
/// it as such and the `acceptInvite` action on the provider flips it.
///
/// [patientId] is a logical link to the single-row patients table (see
/// `lib/db/tables.dart`), carried explicitly so a future multi-patient
/// model lands without a migration.
@freezed
abstract class CareCircleMembership with _$CareCircleMembership {
  const factory CareCircleMembership({
    required String id,
    required String caregiverId,
    required String patientId,
    required PermissionLevel permissionLevel,
    required DateTime invitedAt,

    /// Null while the invite is pending; set to the acceptance time once
    /// the caregiver joins.
    DateTime? acceptedAt,
  }) = _CareCircleMembership;

  factory CareCircleMembership.fromJson(Map<String, dynamic> json) =>
      _$CareCircleMembershipFromJson(json);
}

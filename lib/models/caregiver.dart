import 'package:freezed_annotation/freezed_annotation.dart';

part 'caregiver.freezed.dart';
part 'caregiver.g.dart';

/// A caregiver in the loved one's care circle (TASKS.md Phase 14.25).
///
/// The person side of the care-circle model — the [CareCircleMembership]
/// row carries their permission level and invite state. [role] is the
/// caregiver's relationship to the loved one, an organisational tag the
/// caregiver chooses; nothing here is a medical or legal designation.
///
/// One token per [CaregiverRole] value so the JSON name matches the enum
/// name exactly (`json_serializable` serialises enums by `.name` and the
/// drift columns persist that `.name`).
enum CaregiverRole {
  primary,
  spouse,
  child,
  sibling,
  aide,
  agency,
  friend,
  other,
}

/// One member of the care circle (TASKS.md Phase 14.25, BUILD_SPEC.md
/// §5.14).
///
/// Backs Care Team → Care Circle (BUILD_SPEC.md §5.14). Records the
/// caregiver's [displayName], their [role] relationship to the loved one,
/// and optional [phone] / [email] contact points plus an optional
/// [avatarPath] pointing at an on-disk photo (the roster falls back to
/// initials when it's null). The permission level + invite state live on
/// the companion [CareCircleMembership] so a caregiver can — in a future
/// multi-patient model — belong to more than one circle with different
/// permissions.
@freezed
abstract class Caregiver with _$Caregiver {
  const factory Caregiver({
    required String id,
    required String displayName,
    required CaregiverRole role,

    /// Optional phone number — drives the roster's tap-to-call button.
    String? phone,

    /// Optional email — used by the invite flow (Phase 14.28).
    String? email,

    /// Optional on-disk pointer to a profile photo; the roster shows
    /// initials when this is null.
    String? avatarPath,
  }) = _Caregiver;

  factory Caregiver.fromJson(Map<String, dynamic> json) =>
      _$CaregiverFromJson(json);
}

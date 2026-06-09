import 'package:freezed_annotation/freezed_annotation.dart';

part 'document.freezed.dart';
part 'document.g.dart';

/// Organ-donor status recorded on an [EmergencyCard] (TASKS.md Phase
/// 14.21).
///
/// A self-reported, caregiver-entered fact for ER handoff — not a
/// medical determination. [unknown] is the honest default when the
/// caregiver hasn't confirmed it. One token per value so the JSON name
/// matches the enum name exactly (`json_serializable` serialises enums
/// by `.name` and the round-trip tests pin that).
enum DonorStatus {
  donor,
  notDonor,
  unknown,
}

/// The authority a [PowerOfAttorneyDoc] grants (TASKS.md Phase 14.21).
///
/// [medical] (a.k.a. healthcare proxy), [financial], or [general] (a
/// broad grant covering both). An organisational tag the caregiver
/// chooses; nothing here is legal advice.
enum PoaScope {
  medical,
  financial,
  general,
}

/// Which kind of identification an [IdentificationDoc] captures (TASKS.md
/// Phase 14.21).
///
/// Covers the documents a caregiver typically needs at hand for a
/// hospital visit or benefits paperwork. [insuranceCard] lives here (as
/// an ID document the caregiver photographs) distinct from the structured
/// [Insurance] block on the [EmergencyCard].
enum IdKind {
  driverLicense,
  stateId,
  passport,
  medicare,
  insuranceCard,
}

/// One emergency contact on an [EmergencyCard] (TASKS.md Phase 14.21).
///
/// A named person plus their [relation] to the loved one and a [phone]
/// number — the people ER staff should call. Stored as a JSON object in
/// the `emergency_cards.emergencyContacts` TEXT column (a JSON list of
/// these); see `lib/providers/documents_provider.dart` for the encoding.
@freezed
abstract class EmergencyContact with _$EmergencyContact {
  const factory EmergencyContact({
    required String name,
    required String relation,
    required String phone,
  }) = _EmergencyContact;

  factory EmergencyContact.fromJson(Map<String, dynamic> json) =>
      _$EmergencyContactFromJson(json);
}

/// The loved one's health-insurance block on an [EmergencyCard] (TASKS.md
/// Phase 14.21).
///
/// Stored as a single JSON object in the `emergency_cards.insurance` TEXT
/// column. Free-text fields transcribed from the physical card; the app
/// never validates a policy or contacts a carrier.
@freezed
abstract class Insurance with _$Insurance {
  const factory Insurance({
    required String carrier,
    required String policyNumber,
    required String groupNumber,
  }) = _Insurance;

  factory Insurance.fromJson(Map<String, dynamic> json) =>
      _$InsuranceFromJson(json);
}

/// The printable emergency / hospital-handoff card's structured data
/// (TASKS.md Phase 14.21).
///
/// Lives under Medical → Cards & Documents (BUILD_SPEC.md §5.17). A
/// caregiver-entered snapshot for paramedic / ER staff: the loved one's
/// active [conditions], [medications], and [allergies] (each a list of
/// short strings), the people to call ([emergencyContacts]), the
/// [insurance] block, and [donorStatus]. This is reference data for a
/// handoff — nothing here diagnoses, prescribes, or stages the condition.
///
/// The three string lists are persisted as JSON-encoded TEXT columns and
/// [emergencyContacts] / [insurance] as JSON objects; the model itself is
/// plain typed Dart — the JSON boundary lives in the repository.
///
/// [patientId] FKs (logically — the patients table is single-row, so
/// there's no DB foreign key; see `lib/db/tables.dart`) onto the loved
/// one the install is configured for, carried explicitly so a future
/// multi-patient model lands without a migration. [attachmentPath] is an
/// optional pointer to a scanned/printed copy on disk.
@freezed
abstract class EmergencyCard with _$EmergencyCard {
  const factory EmergencyCard({
    required String id,
    required String patientId,
    required DateTime updatedAt,
    required List<String> conditions,
    required List<String> medications,
    required List<String> allergies,
    required List<EmergencyContact> emergencyContacts,
    required Insurance insurance,
    required DonorStatus donorStatus,

    /// Optional on-disk pointer to a scanned or printed copy of the card.
    String? attachmentPath,

    /// Optional R2 storage key for [attachmentPath]'s uploaded bytes, so the
    /// scan survives a reinstall and syncs across the care circle. Null until
    /// the image has been uploaded (best-effort; see [DocumentBlobService]).
    String? attachmentKey,
  }) = _EmergencyCard;

  factory EmergencyCard.fromJson(Map<String, dynamic> json) =>
      _$EmergencyCardFromJson(json);
}

/// A power-of-attorney document on file for the loved one (TASKS.md Phase
/// 14.21).
///
/// Lives under Medical → Cards & Documents (BUILD_SPEC.md §5.17).
/// Records who holds authority ([agentName], with an optional
/// [alternateName] successor), the [scope] of that authority, when it
/// became [effectiveDate], and an optional [scanPath] to the document
/// image. Organisational record-keeping — not legal advice.
///
/// [patientId] is the logical link to the single loved one (see
/// [EmergencyCard] for why it's not a DB FK). [attachmentPath] mirrors
/// the shared column on the other document kinds; [scanPath] is the
/// POA-specific pointer to the signed document image.
@freezed
abstract class PowerOfAttorneyDoc with _$PowerOfAttorneyDoc {
  const factory PowerOfAttorneyDoc({
    required String id,
    required String patientId,
    required DateTime updatedAt,
    required String agentName,
    required PoaScope scope,
    required DateTime effectiveDate,

    /// Optional successor agent if the primary is unavailable.
    String? alternateName,

    /// Optional on-disk pointer to a scan of the signed document.
    String? scanPath,

    /// Optional R2 storage key for [scanPath]'s uploaded bytes.
    String? scanKey,

    /// Optional shared on-disk attachment pointer (mirrors the other
    /// document kinds' [EmergencyCard.attachmentPath]).
    String? attachmentPath,

    /// Optional R2 storage key for [attachmentPath]'s uploaded bytes.
    String? attachmentKey,
  }) = _PowerOfAttorneyDoc;

  factory PowerOfAttorneyDoc.fromJson(Map<String, dynamic> json) =>
      _$PowerOfAttorneyDocFromJson(json);
}

/// One identification document captured for the loved one (TASKS.md Phase
/// 14.21).
///
/// Lives under Medical → Cards & Documents (BUILD_SPEC.md §5.17). The
/// caregiver records the document [kind], its [idNumber], an optional
/// [expiresOn] date, and optional front/back photos. Reference data the
/// caregiver keeps at hand — the app never validates an ID.
///
/// [patientId] is the logical link to the single loved one (see
/// [EmergencyCard]). [photoFrontPath] / [photoBackPath] point at on-disk
/// images; [attachmentPath] is the shared optional pointer mirrored
/// across all three document kinds.
@freezed
abstract class IdentificationDoc with _$IdentificationDoc {
  const factory IdentificationDoc({
    required String id,
    required String patientId,
    required DateTime updatedAt,
    required IdKind kind,
    required String idNumber,

    /// Optional expiry date — null for documents that don't expire.
    DateTime? expiresOn,

    /// Optional on-disk pointers to the photographed front / back.
    String? photoFrontPath,
    String? photoBackPath,

    /// Optional R2 storage keys for [photoFrontPath] / [photoBackPath]'s
    /// uploaded bytes.
    String? photoFrontKey,
    String? photoBackKey,

    /// Optional shared on-disk attachment pointer (mirrors the other
    /// document kinds' [EmergencyCard.attachmentPath]).
    String? attachmentPath,

    /// Optional R2 storage key for [attachmentPath]'s uploaded bytes.
    String? attachmentKey,
  }) = _IdentificationDoc;

  factory IdentificationDoc.fromJson(Map<String, dynamic> json) =>
      _$IdentificationDocFromJson(json);
}

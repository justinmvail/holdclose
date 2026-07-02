import 'medication.dart';

/// The AI's proposed medication, read off a photographed prescription
/// label or medical document — a **transient** draft, never persisted.
///
/// Deliberately NOT a freezed/persisted model: it exists only for the
/// hop between the scan and the human-approval review screen
/// ([MedicationImportReviewScreen]). The caregiver edits it there and
/// only THEN is a real [Medication] written to disk. Every field is
/// optional because a bottle photo can be partial, blurry, or missing
/// data — the review screen fills the gaps with human input.
///
/// Extraction is pure transcription (reading printed text), never
/// medical advice — consistent with Holdclose's medical guardrails — and
/// nothing is saved without the caregiver's explicit approval.
class MedicationDraft {
  const MedicationDraft({
    this.name,
    this.dosage,
    this.route,
    this.prescriber,
    this.notes,
    this.rxNumber,
    this.quantity,
    this.refills,
    this.pharmacyName,
    this.pharmacyPhone,
    this.dateFilled,
    this.discardAfter,
  });

  /// Medication name as printed on the label (e.g. "Donepezil").
  final String? name;

  /// Dosage verbatim as printed (e.g. "10 mg", "1 tablet").
  final String? dosage;

  /// Best-guess route; null when the label doesn't make it clear (the
  /// review screen then defaults the dropdown to oral).
  final MedicationRoute? route;

  /// Prescribing clinician, if printed on the label.
  final String? prescriber;

  /// Anything else worth surfacing — directions ("take with food"),
  /// frequency. Free text the caregiver can keep or clear.
  final String? notes;

  /// Rx (prescription) number.
  final String? rxNumber;

  /// Quantity dispensed ("180").
  final String? quantity;

  /// Refills remaining ("3", "3 by 5/27/22").
  final String? refills;

  /// Dispensing pharmacy name.
  final String? pharmacyName;

  /// Dispensing pharmacy phone.
  final String? pharmacyPhone;

  /// Date filled, verbatim.
  final String? dateFilled;

  /// Discard-after / use-by date, verbatim.
  final String? discardAfter;

  /// True when the scan produced nothing usable in ANY field — the review
  /// screen opens blank for full manual entry, and a second-photo merge
  /// treats it as "read nothing".
  bool get isEmpty =>
      _blank(name) &&
      _blank(dosage) &&
      _blank(prescriber) &&
      _blank(notes) &&
      _blank(rxNumber) &&
      _blank(quantity) &&
      _blank(refills) &&
      _blank(pharmacyName) &&
      _blank(pharmacyPhone) &&
      _blank(dateFilled) &&
      _blank(discardAfter);

  static bool _blank(String? v) => v == null || v.trim().isEmpty;

  /// Parse the model's JSON reply into a draft. Tolerant by design:
  /// unknown keys are ignored, missing keys stay null, non-string values
  /// are dropped, and a malformed payload yields an empty draft. Never
  /// throws — an unreadable scan must degrade to manual entry, not crash.
  factory MedicationDraft.fromModelJson(Map<String, dynamic> json) {
    String? str(Object? v) {
      if (v is String) {
        final String t = v.trim();
        return t.isEmpty ? null : t;
      }
      return null;
    }

    return MedicationDraft(
      name: str(json['name']),
      dosage: str(json['dosage']),
      route: parseRoute(str(json['route'])),
      prescriber: str(json['prescriber']),
      // Accept a few synonyms the model might use for the free-text
      // "notes" bucket without prompting-in every variant.
      notes: str(json['notes']) ??
          str(json['directions']) ??
          str(json['frequency']),
      rxNumber: str(json['rxNumber']) ?? str(json['rx_number']) ?? str(json['rx']),
      quantity: str(json['quantity']) ?? str(json['qty']),
      refills: str(json['refills']),
      pharmacyName:
          str(json['pharmacyName']) ?? str(json['pharmacy_name']) ?? str(json['pharmacy']),
      pharmacyPhone: str(json['pharmacyPhone']) ??
          str(json['pharmacy_phone']) ??
          str(json['phone']),
      dateFilled: str(json['dateFilled']) ?? str(json['date_filled']),
      discardAfter: str(json['discardAfter']) ??
          str(json['discard_after']) ??
          str(json['discardBy']),
    );
  }

  /// Map a free-text route word onto a [MedicationRoute]. Returns null
  /// only for a null input; an unrecognised-but-present word collapses to
  /// [MedicationRoute.other] (matching the add-med form's "Other" catch).
  static MedicationRoute? parseRoute(String? raw) {
    if (raw == null) return null;
    final String r = raw.toLowerCase();
    if (r.contains('oral') ||
        r.contains('mouth') ||
        r.contains('po') ||
        r.contains('tablet') ||
        r.contains('capsule')) {
      return MedicationRoute.oral;
    }
    if (r.contains('topical') ||
        r.contains('cream') ||
        r.contains('patch') ||
        r.contains('ointment') ||
        r.contains('skin')) {
      return MedicationRoute.topical;
    }
    if (r.contains('inject') ||
        r.contains('subcut') ||
        r.contains('intramus') ||
        r.contains('iv')) {
      return MedicationRoute.injection;
    }
    return MedicationRoute.other;
  }
}

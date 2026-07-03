/// One clinician returned by a provider search (NPI Registry). A transient
/// display model — the caregiver taps one to save it as a real [Provider].
///
/// Carries the full NPI record so the result card can surface every field the
/// registry returns; the card renders only the ones that are non-blank.
class ProviderSearchResult {
  const ProviderSearchResult({
    required this.name,
    this.credential,
    this.enumerationType,
    this.specialty,
    this.specialties = const <String>[],
    this.license,
    this.city,
    this.state,
    this.postalCode,
    this.phone,
    this.fax,
    this.addressLine,
    this.addressLine2,
    this.npi,
  });

  final String name;
  final String? credential;

  /// NPI enumeration type: 'NPI-1' (individual) or 'NPI-2' (organization).
  final String? enumerationType;

  /// Primary taxonomy description (kept for saving onto a [Provider]).
  final String? specialty;

  /// Every taxonomy description on the record (primary first when known).
  final List<String> specialties;

  /// Primary taxonomy license, e.g. "1631 SC".
  final String? license;

  final String? city;
  final String? state;
  final String? postalCode;
  final String? phone;
  final String? fax;

  /// Practice LOCATION street (address_1).
  final String? addressLine;

  /// Suite / unit (address_2).
  final String? addressLine2;

  final String? npi;

  /// "Individual" / "Organization" / null — human label for [enumerationType].
  String? get providerType {
    switch (enumerationType) {
      case 'NPI-1':
        return 'Individual';
      case 'NPI-2':
        return 'Organization';
      default:
        return null;
    }
  }

  /// "North Charleston, SC" (skips blanks).
  String get displayLocation => <String?>[city, state]
      .where((String? e) => (e ?? '').trim().isNotEmpty)
      .join(', ');

  /// Full one-line address for saving onto a [Provider].
  String get fullAddress =>
      <String?>[addressLine, addressLine2, city, state, postalCode]
          .where((String? e) => (e ?? '').trim().isNotEmpty)
          .join(', ');

  /// Name with credential appended ("John Berger, MD").
  String get displayName =>
      (credential ?? '').trim().isEmpty ? name : '$name, ${credential!.trim()}';
}

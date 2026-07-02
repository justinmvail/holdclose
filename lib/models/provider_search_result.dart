/// One clinician returned by a provider search (NPI Registry). A transient
/// display model — the caregiver taps one to save it as a real [Provider].
class ProviderSearchResult {
  const ProviderSearchResult({
    required this.name,
    this.credential,
    this.specialty,
    this.city,
    this.state,
    this.postalCode,
    this.phone,
    this.addressLine,
    this.npi,
  });

  final String name;
  final String? credential;
  final String? specialty;
  final String? city;
  final String? state;
  final String? postalCode;
  final String? phone;
  final String? addressLine;
  final String? npi;

  /// "North Charleston, SC" (skips blanks).
  String get displayLocation => <String?>[city, state]
      .where((String? e) => (e ?? '').trim().isNotEmpty)
      .join(', ');

  /// Full one-line address for saving onto a [Provider].
  String get fullAddress => <String?>[addressLine, city, state, postalCode]
      .where((String? e) => (e ?? '').trim().isNotEmpty)
      .join(', ');

  /// Name with credential appended ("John Berger, MD").
  String get displayName =>
      (credential ?? '').trim().isEmpty ? name : '$name, ${credential!.trim()}';
}

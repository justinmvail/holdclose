import 'package:dio/dio.dart';

import '../models/provider_search_result.dart';

/// Searches for clinicians via the free public **NPI Registry** API
/// (npiregistry.cms.hhs.gov) — no key, no cost. Behind an interface so tests
/// use a deterministic fake instead of hitting the network.
abstract class NpiProviderService {
  /// Search by last name, specialty, and/or location. Returns matches, or
  /// null on a transport error (callers show a retry hint). MUST NOT throw.
  Future<List<ProviderSearchResult>?> search({
    String? name,
    String? specialty,
    String? city,
    String? state,
    String? postalCode,
  });
}

/// Production NPI-Registry-backed search.
class RealNpiProviderService implements NpiProviderService {
  const RealNpiProviderService({this.dio});

  final Dio? dio;

  static const String _endpoint = 'https://npiregistry.cms.hhs.gov/api/';

  @override
  Future<List<ProviderSearchResult>?> search({
    String? name,
    String? specialty,
    String? city,
    String? state,
    String? postalCode,
  }) async {
    final Dio d = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ));
    final Map<String, dynamic> params = <String, dynamic>{
      'version': '2.1',
      'limit': '20',
      if ((name ?? '').trim().isNotEmpty) 'last_name': name!.trim(),
      if ((specialty ?? '').trim().isNotEmpty)
        'taxonomy_description': specialty!.trim(),
      if ((city ?? '').trim().isNotEmpty) 'city': city!.trim(),
      if ((state ?? '').trim().isNotEmpty) 'state': state!.trim(),
      if ((postalCode ?? '').trim().isNotEmpty) 'postal_code': postalCode!.trim(),
    };
    try {
      final Response<dynamic> resp =
          await d.get<dynamic>(_endpoint, queryParameters: params);
      return parseNpiResults(resp.data);
    } catch (_) {
      return null;
    }
  }
}

/// Deterministic fake for tests / demo.
class FakeNpiProviderService implements NpiProviderService {
  const FakeNpiProviderService();

  @override
  Future<List<ProviderSearchResult>?> search({
    String? name,
    String? specialty,
    String? city,
    String? state,
    String? postalCode,
  }) async {
    return const <ProviderSearchResult>[
      ProviderSearchResult(
        name: 'John Berger',
        credential: 'MD',
        enumerationType: 'NPI-1',
        specialty: 'Neurology',
        specialties: <String>['Neurology', 'Vascular Neurology'],
        license: '1631 SC',
        city: 'North Charleston',
        state: 'SC',
        postalCode: '29456',
        phone: '843-767-4500',
        fax: '843-767-4599',
        addressLine: '2135 Ashley Phosphate Rd',
        addressLine2: 'Suite 200',
        npi: '1234567890',
      ),
      // Deliberately sparse — most fields blank, so the card must OMIT them.
      ProviderSearchResult(
        name: 'Aisha Patel',
        credential: 'MD',
        specialty: 'Neurology',
        city: 'Charleston',
        state: 'SC',
        npi: '1987654320',
      ),
    ];
  }
}

/// Parse the NPI Registry response into results. Tolerant of the API's
/// nested shape; skips entries without a usable name. Visible for tests.
List<ProviderSearchResult> parseNpiResults(dynamic data) {
  final Map<String, dynamic> map =
      data is Map<String, dynamic> ? data : <String, dynamic>{};
  final dynamic results = map['results'];
  if (results is! List) return const <ProviderSearchResult>[];

  String? s(Object? v) {
    final String t = (v ?? '').toString().trim();
    return t.isEmpty ? null : t;
  }

  final List<ProviderSearchResult> out = <ProviderSearchResult>[];
  for (final dynamic r in results) {
    if (r is! Map) continue;
    final Map<dynamic, dynamic> basic =
        r['basic'] is Map ? r['basic'] as Map : <dynamic, dynamic>{};
    final String? org = s(basic['organization_name']);
    final String name = org ??
        <String?>[s(basic['first_name']), s(basic['last_name'])]
            .where((String? e) => e != null)
            .join(' ');
    if (name.trim().isEmpty) continue;

    // Taxonomies: primary specialty (+ its license), and every listed desc.
    String? specialty;
    String? license;
    final List<String> specialties = <String>[];
    final dynamic taxes = r['taxonomies'];
    if (taxes is List) {
      for (final dynamic t in taxes) {
        if (t is! Map) continue;
        final String? desc = s(t['desc']);
        if (desc != null && !specialties.contains(desc)) specialties.add(desc);
        specialty ??= desc;
        if (t['primary'] == true) {
          specialty = desc;
          license = <String?>[s(t['license']), s(t['state'])]
              .where((String? e) => e != null)
              .join(' ');
          if (license.isEmpty) license = null;
        }
      }
    }

    // Practice LOCATION address (fall back to the first listed).
    Map<dynamic, dynamic>? loc;
    final dynamic addrs = r['addresses'];
    if (addrs is List) {
      for (final dynamic a in addrs) {
        if (a is Map && a['address_purpose'] == 'LOCATION') {
          loc = a;
          break;
        }
      }
      if (loc == null && addrs.isNotEmpty && addrs.first is Map) {
        loc = addrs.first as Map;
      }
    }

    out.add(ProviderSearchResult(
      name: name,
      credential: s(basic['credential']),
      enumerationType: s(r['enumeration_type']),
      specialty: specialty,
      specialties: specialties,
      license: license,
      city: s(loc?['city']),
      state: s(loc?['state']),
      postalCode: s(loc?['postal_code']),
      phone: s(loc?['telephone_number']),
      fax: s(loc?['fax_number']),
      addressLine: s(loc?['address_1']),
      addressLine2: s(loc?['address_2']),
      npi: s(r['number']),
    ));
  }
  return out;
}

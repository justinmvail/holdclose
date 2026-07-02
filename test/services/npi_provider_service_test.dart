import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/provider_search_result.dart';
import 'package:holdclose/services/npi_provider_service.dart';

/// Coverage for the NPI response parser + the fake.
void main() {
  group('parseNpiResults', () {
    test('parses name, primary specialty, and the LOCATION address', () {
      final Map<String, dynamic> data = <String, dynamic>{
        'results': <dynamic>[
          <String, dynamic>{
            'number': '1234567890',
            'basic': <String, dynamic>{
              'first_name': 'John',
              'last_name': 'Berger',
              'credential': 'MD',
            },
            'taxonomies': <dynamic>[
              <String, dynamic>{'desc': 'Internal Medicine', 'primary': false},
              <String, dynamic>{'desc': 'Neurology', 'primary': true},
            ],
            'addresses': <dynamic>[
              <String, dynamic>{'address_purpose': 'MAILING', 'city': 'Nowhere'},
              <String, dynamic>{
                'address_purpose': 'LOCATION',
                'address_1': '2135 Ashley Phosphate Rd',
                'city': 'North Charleston',
                'state': 'SC',
                'postal_code': '29456',
                'telephone_number': '843-767-4500',
              },
            ],
          },
        ],
      };
      final List<ProviderSearchResult> results = parseNpiResults(data);
      expect(results, hasLength(1));
      final ProviderSearchResult r = results.single;
      expect(r.name, 'John Berger');
      expect(r.displayName, 'John Berger, MD');
      expect(r.specialty, 'Neurology'); // primary wins
      expect(r.city, 'North Charleston');
      expect(r.state, 'SC');
      expect(r.phone, '843-767-4500');
    });

    test('organization name; skips nameless; empty/wrong shapes', () {
      expect(parseNpiResults(<String, dynamic>{'results': <dynamic>[]}), isEmpty);
      expect(parseNpiResults('nope'), isEmpty);
      final List<ProviderSearchResult> org = parseNpiResults(<String, dynamic>{
        'results': <dynamic>[
          <String, dynamic>{
            'basic': <String, dynamic>{'organization_name': 'Clinic X'}
          }
        ],
      });
      expect(org.single.name, 'Clinic X');
    });
  });

  group('FakeNpiProviderService', () {
    test('returns canned results', () async {
      const FakeNpiProviderService s = FakeNpiProviderService();
      final List<ProviderSearchResult>? r = await s.search(name: 'Berger');
      expect(r, isNotNull);
      expect(r!.length, greaterThanOrEqualTo(1));
    });
  });
}

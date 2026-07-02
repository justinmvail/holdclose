import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/models/medication_draft.dart';

/// Unit coverage for the transient [MedicationDraft] the AI scan produces
/// — parsing tolerance (partial/blurry labels) and route mapping. The
/// draft must NEVER throw on a bad model reply; it degrades to empty so
/// the review screen opens blank for manual entry.
void main() {
  group('MedicationDraft.fromModelJson', () {
    test('parses a full object', () {
      final MedicationDraft d = MedicationDraft.fromModelJson(
        <String, dynamic>{
          'name': 'Donepezil',
          'dosage': '10 mg',
          'route': 'oral',
          'prescriber': 'Dr. Kim',
          'notes': 'Take at bedtime.',
        },
      );
      expect(d.name, 'Donepezil');
      expect(d.dosage, '10 mg');
      expect(d.route, MedicationRoute.oral);
      expect(d.prescriber, 'Dr. Kim');
      expect(d.notes, 'Take at bedtime.');
      expect(d.isEmpty, isFalse);
    });

    test('blank strings become null; missing keys stay null; isEmpty', () {
      final MedicationDraft d = MedicationDraft.fromModelJson(
        <String, dynamic>{'name': '   ', 'dosage': '', 'route': ''},
      );
      expect(d.name, isNull);
      expect(d.dosage, isNull);
      expect(d.route, isNull);
      expect(d.prescriber, isNull);
      expect(d.notes, isNull);
      expect(d.isEmpty, isTrue);
    });

    test('notes falls back to directions / frequency synonyms', () {
      expect(
        MedicationDraft.fromModelJson(
            <String, dynamic>{'directions': 'with food'}).notes,
        'with food',
      );
      expect(
        MedicationDraft.fromModelJson(
            <String, dynamic>{'frequency': 'twice daily'}).notes,
        'twice daily',
      );
    });

    test('non-string values are dropped, not coerced', () {
      final MedicationDraft d = MedicationDraft.fromModelJson(
        <String, dynamic>{'name': 123, 'dosage': null},
      );
      expect(d.name, isNull);
      expect(d.dosage, isNull);
    });

    test('parses the prescription-label fields', () {
      final MedicationDraft d = MedicationDraft.fromModelJson(
        <String, dynamic>{
          'name': 'Tizanidine',
          'rxNumber': '1687749',
          'quantity': '180',
          'refills': '3 by 5/27/22',
          'pharmacyName': 'CVS Pharmacy',
          'pharmacyPhone': '843-767-4500',
          'dateFilled': '12/3/21',
          'discardAfter': '12/3/22',
        },
      );
      expect(d.rxNumber, '1687749');
      expect(d.quantity, '180');
      expect(d.refills, '3 by 5/27/22');
      expect(d.pharmacyName, 'CVS Pharmacy');
      expect(d.pharmacyPhone, '843-767-4500');
      expect(d.dateFilled, '12/3/21');
      expect(d.discardAfter, '12/3/22');
      expect(d.isEmpty, isFalse);
    });

    test('accepts snake_case / synonym keys for label fields', () {
      final MedicationDraft d = MedicationDraft.fromModelJson(
        <String, dynamic>{
          'rx_number': 'RX-9',
          'qty': '30',
          'pharmacy': 'Walgreens',
          'pharmacy_phone': '555-1212',
          'date_filled': '1/1/26',
        },
      );
      expect(d.rxNumber, 'RX-9');
      expect(d.quantity, '30');
      expect(d.pharmacyName, 'Walgreens');
      expect(d.pharmacyPhone, '555-1212');
      expect(d.dateFilled, '1/1/26');
    });

    test('isEmpty stays true when only whitespace label fields present', () {
      final MedicationDraft d = MedicationDraft.fromModelJson(
        <String, dynamic>{'quantity': '  ', 'refills': ''},
      );
      expect(d.isEmpty, isTrue);
    });
  });

  group('MedicationDraft.parseRoute', () {
    test('maps known route language', () {
      expect(MedicationDraft.parseRoute('by mouth'), MedicationRoute.oral);
      expect(MedicationDraft.parseRoute('1 tablet'), MedicationRoute.oral);
      expect(
          MedicationDraft.parseRoute('apply to skin'), MedicationRoute.topical);
      expect(MedicationDraft.parseRoute('subcutaneous injection'),
          MedicationRoute.injection);
    });

    test('present-but-unknown collapses to other; null stays null', () {
      expect(MedicationDraft.parseRoute('nebulized'), MedicationRoute.other);
      expect(MedicationDraft.parseRoute(null), isNull);
    });
  });
}

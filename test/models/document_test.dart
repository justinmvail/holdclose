import 'package:holdclose/models/document.dart';
import 'package:flutter_test/flutter_test.dart';

EmergencyCard _card({
  String id = 'ec-1',
  String patientId = 'mary',
  List<String> conditions = const <String>['Alzheimer\'s', 'Hypertension'],
  List<String> medications = const <String>['Donepezil 10 mg'],
  List<String> allergies = const <String>['Penicillin'],
  String? attachmentPath,
}) =>
    EmergencyCard(
      id: id,
      patientId: patientId,
      updatedAt: DateTime.utc(2026, 6, 1, 9),
      conditions: conditions,
      medications: medications,
      allergies: allergies,
      emergencyContacts: const <EmergencyContact>[
        EmergencyContact(
            name: 'Sarah Henderson', relation: 'Daughter', phone: '555-0100'),
        EmergencyContact(
            name: 'Dr. Ortega', relation: 'Physician', phone: '555-0188'),
      ],
      insurance: const Insurance(
        carrier: 'Medicare',
        policyNumber: '1EG4-TE5-MK72',
        groupNumber: 'GRP-001',
      ),
      donorStatus: DonorStatus.donor,
      attachmentPath: attachmentPath,
    );

void main() {
  // ---- Enums ------------------------------------------------------------

  group('DonorStatus', () {
    test('exposes the three values', () {
      expect(DonorStatus.values, hasLength(3));
      expect(
        DonorStatus.values,
        containsAll(<DonorStatus>[
          DonorStatus.donor,
          DonorStatus.notDonor,
          DonorStatus.unknown,
        ]),
      );
    });

    test('serialises to its string name on the parent card', () {
      for (final DonorStatus s in DonorStatus.values) {
        expect(_card().copyWith(donorStatus: s).toJson()['donorStatus'],
            s.name);
      }
    });
  });

  group('PoaScope', () {
    test('exposes the three spec values', () {
      expect(PoaScope.values, hasLength(3));
      expect(
        PoaScope.values,
        containsAll(<PoaScope>[
          PoaScope.medical,
          PoaScope.financial,
          PoaScope.general,
        ]),
      );
    });
  });

  group('IdKind', () {
    test('exposes the five spec values', () {
      expect(IdKind.values, hasLength(5));
      expect(
        IdKind.values,
        containsAll(<IdKind>[
          IdKind.driverLicense,
          IdKind.stateId,
          IdKind.passport,
          IdKind.medicare,
          IdKind.insuranceCard,
        ]),
      );
    });
  });

  // ---- EmergencyCard round-trip -----------------------------------------

  group('EmergencyCard round-trip', () {
    test('a fully populated card survives toJson -> fromJson unchanged', () {
      final EmergencyCard card = _card(attachmentPath: '/docs/ec.pdf');
      expect(EmergencyCard.fromJson(card.toJson()), equals(card));
    });

    test('the nested contacts + insurance survive the round-trip', () {
      final EmergencyCard restored =
          EmergencyCard.fromJson(_card().toJson());
      expect(restored.emergencyContacts, hasLength(2));
      expect(restored.emergencyContacts.first.relation, 'Daughter');
      expect(restored.insurance.policyNumber, '1EG4-TE5-MK72');
    });

    test('the three string lists survive empty', () {
      final EmergencyCard empty = _card(
        conditions: const <String>[],
        medications: const <String>[],
        allergies: const <String>[],
      );
      final EmergencyCard restored = EmergencyCard.fromJson(empty.toJson());
      expect(restored.conditions, isEmpty);
      expect(restored.medications, isEmpty);
      expect(restored.allergies, isEmpty);
    });

    test('attachmentPath is optional', () {
      expect(_card().attachmentPath, isNull);
      expect(EmergencyCard.fromJson(_card().toJson()).attachmentPath, isNull);
    });
  });

  // ---- PowerOfAttorneyDoc round-trip ------------------------------------

  group('PowerOfAttorneyDoc round-trip', () {
    test('a fully populated doc survives unchanged', () {
      final PowerOfAttorneyDoc doc = PowerOfAttorneyDoc(
        id: 'poa-1',
        patientId: 'mary',
        updatedAt: DateTime.utc(2026, 6, 1, 9),
        agentName: 'Sarah Henderson',
        alternateName: 'Mark Henderson',
        scope: PoaScope.medical,
        effectiveDate: DateTime.utc(2024, 1, 15),
        scanPath: '/docs/poa.pdf',
        attachmentPath: '/docs/poa-att.pdf',
      );
      expect(PowerOfAttorneyDoc.fromJson(doc.toJson()), equals(doc));
      expect(doc.toJson()['scope'], 'medical');
    });

    test('the optional fields default to null', () {
      final PowerOfAttorneyDoc doc = PowerOfAttorneyDoc(
        id: 'poa-2',
        patientId: 'mary',
        updatedAt: DateTime.utc(2026, 6, 1),
        agentName: 'Sarah',
        scope: PoaScope.financial,
        effectiveDate: DateTime.utc(2024, 1, 15),
      );
      final PowerOfAttorneyDoc restored =
          PowerOfAttorneyDoc.fromJson(doc.toJson());
      expect(restored.alternateName, isNull);
      expect(restored.scanPath, isNull);
      expect(restored.attachmentPath, isNull);
    });
  });

  // ---- IdentificationDoc round-trip -------------------------------------

  group('IdentificationDoc round-trip', () {
    test('a fully populated doc survives unchanged', () {
      final IdentificationDoc doc = IdentificationDoc(
        id: 'id-1',
        patientId: 'mary',
        updatedAt: DateTime.utc(2026, 6, 1, 9),
        kind: IdKind.driverLicense,
        idNumber: 'D1234567',
        expiresOn: DateTime.utc(2028, 3, 1),
        photoFrontPath: '/docs/front.jpg',
        photoBackPath: '/docs/back.jpg',
        attachmentPath: '/docs/id-att.jpg',
      );
      expect(IdentificationDoc.fromJson(doc.toJson()), equals(doc));
      expect(doc.toJson()['kind'], 'driverLicense');
    });

    test('expiresOn + photo paths are optional', () {
      final IdentificationDoc doc = IdentificationDoc(
        id: 'id-2',
        patientId: 'mary',
        updatedAt: DateTime.utc(2026, 6, 1),
        kind: IdKind.passport,
        idNumber: 'P9999',
      );
      final IdentificationDoc restored =
          IdentificationDoc.fromJson(doc.toJson());
      expect(restored.expiresOn, isNull);
      expect(restored.photoFrontPath, isNull);
      expect(restored.photoBackPath, isNull);
    });
  });
}

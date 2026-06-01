import 'dart:convert';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/providers/documents_provider.dart';
import 'package:careblazers/models/document.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Documents tables (TASKS.md Phase 14.21)', () {
    late CareblazersDatabase db;
    late DocumentsRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = DocumentsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    EmergencyCard buildCard() => EmergencyCard(
          id: 'ec-1',
          patientId: 'mary',
          updatedAt: DateTime.utc(2026, 6, 1, 9),
          conditions: const <String>['Alzheimer\'s', 'Hypertension'],
          medications: const <String>['Donepezil 10 mg', 'Lisinopril 5 mg'],
          allergies: const <String>['Penicillin'],
          emergencyContacts: const <EmergencyContact>[
            EmergencyContact(
                name: 'Sarah', relation: 'Daughter', phone: '555-0100'),
          ],
          insurance: const Insurance(
            carrier: 'Medicare',
            policyNumber: '1EG4-TE5-MK72',
            groupNumber: 'GRP-001',
          ),
          donorStatus: DonorStatus.donor,
        );

    // ---- Columns hold what the model carries ----------------------------

    test('emergency card list fields land as JSON-encoded TEXT columns',
        () async {
      await repo.upsertEmergencyCard(buildCard());

      final EmergencyCardsTableData row =
          await db.select(db.emergencyCardsTable).getSingle();

      // The lifted scalar columns carry the typed values directly.
      expect(row.patientId, 'mary');
      expect(row.updatedAtMs, DateTime.utc(2026, 6, 1, 9).millisecondsSinceEpoch);
      expect(row.donorStatus, 'donor');

      // The list / structured columns carry JSON that decodes verbatim.
      expect(jsonDecode(row.conditions),
          <String>['Alzheimer\'s', 'Hypertension']);
      expect(jsonDecode(row.medications), hasLength(2));
      expect((jsonDecode(row.emergencyContacts) as List<dynamic>).single,
          <String, dynamic>{
            'name': 'Sarah',
            'relation': 'Daughter',
            'phone': '555-0100',
          });
      expect((jsonDecode(row.insurance) as Map<String, dynamic>)['carrier'],
          'Medicare');
    });

    test('POA + ID enum + date columns carry name / epoch-ms', () async {
      await repo.upsertPoa(PowerOfAttorneyDoc(
        id: 'poa-1',
        patientId: 'mary',
        updatedAt: DateTime.utc(2026, 6, 1),
        agentName: 'Sarah',
        scope: PoaScope.financial,
        effectiveDate: DateTime.utc(2024, 1, 15),
      ));
      await repo.upsertId(IdentificationDoc(
        id: 'id-1',
        patientId: 'mary',
        updatedAt: DateTime.utc(2026, 6, 1),
        kind: IdKind.passport,
        idNumber: 'P9999',
      ));

      final PowerOfAttorneyDocsTableData poaRow =
          await db.select(db.powerOfAttorneyDocsTable).getSingle();
      expect(poaRow.scope, 'financial');
      expect(poaRow.effectiveDateMs,
          DateTime.utc(2024, 1, 15).millisecondsSinceEpoch);
      expect(poaRow.alternateName, isNull);

      final IdentificationDocsTableData idRow =
          await db.select(db.identificationDocsTable).getSingle();
      expect(idRow.kind, 'passport');
      expect(idRow.expiresOnMs, isNull);
    });

    // ---- wipeAll() includes the new tables (Phase 14.21) ----------------

    test('wipeAll() truncates all three documents tables', () async {
      await repo.upsertEmergencyCard(buildCard());
      await repo.upsertPoa(PowerOfAttorneyDoc(
        id: 'poa-1',
        patientId: 'mary',
        updatedAt: DateTime.utc(2026, 6, 1),
        agentName: 'Sarah',
        scope: PoaScope.medical,
        effectiveDate: DateTime.utc(2024, 1, 15),
      ));
      await repo.upsertId(IdentificationDoc(
        id: 'id-1',
        patientId: 'mary',
        updatedAt: DateTime.utc(2026, 6, 1),
        kind: IdKind.medicare,
        idNumber: 'M1',
      ));

      await db.wipeAll();

      expect(await db.select(db.emergencyCardsTable).get(), isEmpty);
      expect(await db.select(db.powerOfAttorneyDocsTable).get(), isEmpty);
      expect(await db.select(db.identificationDocsTable).get(), isEmpty);
    });

    test('schemaVersion is 9 (calendar migration step)', () {
      expect(db.schemaVersion, 9);
    });
  });
}

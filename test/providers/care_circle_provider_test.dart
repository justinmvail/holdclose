import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_circle_membership.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const String _patientId = 'demo-patient-mary';

Caregiver _caregiver({
  required String id,
  String displayName = 'Sarah Henderson',
  CaregiverRole role = CaregiverRole.child,
  String? phone,
  String? email,
}) =>
    Caregiver(
      id: id,
      displayName: displayName,
      role: role,
      phone: phone,
      email: email,
    );

CareCircleMembership _membership({
  required String id,
  required String caregiverId,
  PermissionLevel permissionLevel = PermissionLevel.viewer,
  DateTime? acceptedAt,
}) =>
    CareCircleMembership(
      id: id,
      caregiverId: caregiverId,
      patientId: _patientId,
      permissionLevel: permissionLevel,
      invitedAt: DateTime.utc(2026, 5, 1),
      acceptedAt: acceptedAt,
    );

void main() {
  group('CareCircleRepository — CRUD', () {
    late CareblazersDatabase db;
    late CareCircleRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = CareCircleRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('caregiver round-trips through typed columns', () async {
      await repo.upsertCaregiver(_caregiver(
        id: 'c1',
        role: CaregiverRole.aide,
        phone: '555-0100',
        email: 'aide@example.com',
      ));

      final Caregiver? loaded = await repo.getCaregiver('c1');
      expect(loaded, isNotNull);
      expect(loaded!.role, CaregiverRole.aide);
      expect(loaded.phone, '555-0100');
      expect(loaded.email, 'aide@example.com');
    });

    test('listCaregivers is ordered by display name', () async {
      await repo.upsertCaregiver(_caregiver(id: 'c1', displayName: 'Zane'));
      await repo.upsertCaregiver(_caregiver(id: 'c2', displayName: 'Amy'));

      final List<Caregiver> all = await repo.listCaregivers();
      expect(all.map((Caregiver c) => c.displayName), <String>['Amy', 'Zane']);
    });

    test('membership round-trips, including the null acceptedAt', () async {
      await repo.upsertCaregiver(_caregiver(id: 'c1'));
      await repo.upsertMembership(_membership(
        id: 'm1',
        caregiverId: 'c1',
        permissionLevel: PermissionLevel.editor,
      ));

      final CareCircleMembership? loaded = await repo.getMembership('m1');
      expect(loaded, isNotNull);
      expect(loaded!.permissionLevel, PermissionLevel.editor);
      expect(loaded.acceptedAt, isNull);
    });

    test('deleting a caregiver cascades to their membership', () async {
      await repo.upsertCaregiver(_caregiver(id: 'c1'));
      await repo.upsertMembership(_membership(id: 'm1', caregiverId: 'c1'));

      await repo.deleteCaregiver('c1');

      expect(await repo.getCaregiver('c1'), isNull);
      expect(await repo.listMemberships(), isEmpty);
    });

    test('wipeAll() truncates both care-circle tables', () async {
      await repo.upsertCaregiver(_caregiver(id: 'c1'));
      await repo.upsertMembership(_membership(id: 'm1', caregiverId: 'c1'));

      await db.wipeAll();

      expect(await repo.listCaregivers(), isEmpty);
      expect(await repo.listMemberships(), isEmpty);
    });
  });
}

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_circle_membership.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

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

  group('CareCircle notifier', () {
    late CareblazersDatabase db;
    late CareCircleRepository repo;

    ProviderContainer makeContainer() {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          careCircleRepositoryProvider.overrideWithValue(repo),
          careCircleClockProvider.overrideWithValue(
            () => DateTime.utc(2026, 6, 1, 12),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = CareCircleRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('build joins caregivers to memberships, owner first then by name',
        () async {
      await repo.upsertCaregiver(_caregiver(id: 'c1', displayName: 'Zoe'));
      await repo.upsertCaregiver(_caregiver(id: 'c2', displayName: 'Owner Olga'));
      await repo.upsertCaregiver(_caregiver(id: 'c3', displayName: 'Amy'));
      await repo.upsertMembership(_membership(
          id: 'm1', caregiverId: 'c1', permissionLevel: PermissionLevel.viewer));
      await repo.upsertMembership(_membership(
          id: 'm2', caregiverId: 'c2', permissionLevel: PermissionLevel.owner));
      await repo.upsertMembership(_membership(
          id: 'm3',
          caregiverId: 'c3',
          permissionLevel: PermissionLevel.viewer));

      final ProviderContainer container = makeContainer();
      final List<CareCircleMember> members =
          await container.read(careCircleProvider.future);

      // Owner first, then the two viewers alphabetically (Amy before Zoe).
      expect(
        members.map((CareCircleMember m) => m.caregiver.displayName),
        <String>['Owner Olga', 'Amy', 'Zoe'],
      );
    });

    test('a caregiver with no membership is left off the roster', () async {
      await repo.upsertCaregiver(_caregiver(id: 'c1'));

      final ProviderContainer container = makeContainer();
      final List<CareCircleMember> members =
          await container.read(careCircleProvider.future);
      expect(members, isEmpty);
    });

    test('acceptInvite flips acceptedAt and clears pending', () async {
      await repo.upsertCaregiver(_caregiver(id: 'c1'));
      await repo.upsertMembership(_membership(id: 'm1', caregiverId: 'c1'));

      final ProviderContainer container = makeContainer();
      await container.read(careCircleProvider.future);

      final CareCircle notifier =
          container.read(careCircleProvider.notifier);
      expect(notifier.pendingInvites, hasLength(1));

      await notifier.acceptInvite('m1');
      final List<CareCircleMember> after =
          await container.read(careCircleProvider.future);

      expect(after.single.isPending, isFalse);
      expect(after.single.membership.acceptedAt, DateTime.utc(2026, 6, 1, 12));
      expect(notifier.pendingInvites, isEmpty);
    });

    test('acceptInvite is a no-op on an already-accepted membership',
        () async {
      await repo.upsertCaregiver(_caregiver(id: 'c1'));
      await repo.upsertMembership(_membership(
        id: 'm1',
        caregiverId: 'c1',
        acceptedAt: DateTime.utc(2026, 1, 1),
      ));

      final ProviderContainer container = makeContainer();
      await container.read(careCircleProvider.future);
      await container.read(careCircleProvider.notifier).acceptInvite('m1');

      final List<CareCircleMember> after =
          await container.read(careCircleProvider.future);
      expect(after.single.membership.acceptedAt, DateTime.utc(2026, 1, 1));
    });

    test('editRole and editPermission persist through the notifier',
        () async {
      await repo.upsertCaregiver(
          _caregiver(id: 'c1', role: CaregiverRole.friend));
      await repo.upsertMembership(_membership(
          id: 'm1',
          caregiverId: 'c1',
          permissionLevel: PermissionLevel.viewer));

      final ProviderContainer container = makeContainer();
      await container.read(careCircleProvider.future);
      final CareCircle notifier = container.read(careCircleProvider.notifier);

      await notifier.editRole('c1', CaregiverRole.aide);
      await notifier.editPermission('m1', PermissionLevel.editor);

      final CareCircleMember member =
          (await container.read(careCircleProvider.future)).single;
      expect(member.caregiver.role, CaregiverRole.aide);
      expect(member.membership.permissionLevel, PermissionLevel.editor);
    });

    test('addMember then removeMember', () async {
      final ProviderContainer container = makeContainer();
      await container.read(careCircleProvider.future);
      final CareCircle notifier = container.read(careCircleProvider.notifier);

      await notifier.addMember(
        caregiver: _caregiver(id: 'c1'),
        membership: _membership(id: 'm1', caregiverId: 'c1'),
      );
      expect(await container.read(careCircleProvider.future), hasLength(1));

      await notifier.removeMember('c1');
      expect(await container.read(careCircleProvider.future), isEmpty);
    });
  });
}

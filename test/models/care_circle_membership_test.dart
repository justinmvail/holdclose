import 'package:careblazers/models/care_circle_membership.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---- PermissionLevel enum ---------------------------------------------

  group('PermissionLevel', () {
    test('exposes the three spec values', () {
      expect(PermissionLevel.values, hasLength(3));
      expect(
        PermissionLevel.values,
        containsAll(<PermissionLevel>[
          PermissionLevel.owner,
          PermissionLevel.editor,
          PermissionLevel.viewer,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final PermissionLevel level in PermissionLevel.values) {
        final CareCircleMembership m = CareCircleMembership(
          id: 'm-${level.name}',
          caregiverId: 'cg-1',
          patientId: 'mary',
          permissionLevel: level,
          invitedAt: DateTime.utc(2026, 1, 1),
        );
        expect(m.toJson()['permissionLevel'], level.name);
      }
    });
  });

  // ---- fromJson / toJson round-trip -------------------------------------

  group('CareCircleMembership round-trip', () {
    test('an accepted membership survives toJson -> fromJson unchanged', () {
      final CareCircleMembership membership = CareCircleMembership(
        id: 'm-1',
        caregiverId: 'cg-1',
        patientId: 'mary',
        permissionLevel: PermissionLevel.editor,
        invitedAt: DateTime.utc(2026, 1, 5, 9, 30),
        acceptedAt: DateTime.utc(2026, 1, 6, 14, 15),
      );

      final CareCircleMembership restored =
          CareCircleMembership.fromJson(membership.toJson());

      expect(restored, equals(membership));
    });

    test('a pending invite keeps its null acceptedAt across the round-trip',
        () {
      final CareCircleMembership pending = CareCircleMembership(
        id: 'm-2',
        caregiverId: 'cg-2',
        patientId: 'mary',
        permissionLevel: PermissionLevel.viewer,
        invitedAt: DateTime.utc(2026, 1, 10),
      );

      expect(pending.acceptedAt, isNull);

      final CareCircleMembership restored =
          CareCircleMembership.fromJson(pending.toJson());

      expect(restored.acceptedAt, isNull);
      expect(restored, equals(pending));
    });

    test('acceptInvite-style copyWith flips acceptedAt from null to a time',
        () {
      final CareCircleMembership pending = CareCircleMembership(
        id: 'm-3',
        caregiverId: 'cg-3',
        patientId: 'mary',
        permissionLevel: PermissionLevel.editor,
        invitedAt: DateTime.utc(2026, 2, 1),
      );

      final DateTime acceptedAt = DateTime.utc(2026, 2, 2, 8);
      final CareCircleMembership accepted =
          pending.copyWith(acceptedAt: acceptedAt);

      expect(accepted.acceptedAt, acceptedAt);
      expect(accepted.id, pending.id);
      expect(accepted.permissionLevel, pending.permissionLevel);
      expect(accepted.invitedAt, pending.invitedAt);
    });
  });
}

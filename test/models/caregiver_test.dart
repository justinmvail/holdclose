import 'package:holdclose/models/caregiver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---- CaregiverRole enum -----------------------------------------------

  group('CaregiverRole', () {
    test('exposes the eight spec values', () {
      expect(CaregiverRole.values, hasLength(8));
      expect(
        CaregiverRole.values,
        containsAll(<CaregiverRole>[
          CaregiverRole.primary,
          CaregiverRole.spouse,
          CaregiverRole.child,
          CaregiverRole.sibling,
          CaregiverRole.aide,
          CaregiverRole.agency,
          CaregiverRole.friend,
          CaregiverRole.other,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final CaregiverRole role in CaregiverRole.values) {
        final Caregiver c = Caregiver(
          id: 'cg-${role.name}',
          displayName: 'Pat',
          role: role,
        );
        expect(c.toJson()['role'], role.name);
      }
    });
  });

  // ---- fromJson / toJson round-trip -------------------------------------

  group('Caregiver round-trip', () {
    test('a fully populated caregiver survives toJson -> fromJson unchanged',
        () {
      const Caregiver caregiver = Caregiver(
        id: 'cg-1',
        displayName: 'Jane Henderson',
        role: CaregiverRole.child,
        phone: '+1-555-0100',
        email: 'jane@example.com',
        avatarPath: '/photos/jane.jpg',
      );

      final Caregiver restored = Caregiver.fromJson(caregiver.toJson());

      expect(restored, equals(caregiver));
    });

    test('optional fields default to null and survive the round-trip', () {
      const Caregiver caregiver = Caregiver(
        id: 'cg-2',
        displayName: 'Aide Agency',
        role: CaregiverRole.agency,
      );

      expect(caregiver.phone, isNull);
      expect(caregiver.email, isNull);
      expect(caregiver.avatarPath, isNull);

      final Caregiver restored = Caregiver.fromJson(caregiver.toJson());
      expect(restored, equals(caregiver));
      expect(restored.phone, isNull);
      expect(restored.email, isNull);
      expect(restored.avatarPath, isNull);
    });

    test('copyWith swaps the role without touching the rest', () {
      const Caregiver caregiver = Caregiver(
        id: 'cg-3',
        displayName: 'Sam',
        role: CaregiverRole.sibling,
        phone: '+1-555-0199',
      );

      final Caregiver promoted =
          caregiver.copyWith(role: CaregiverRole.primary);

      expect(promoted.role, CaregiverRole.primary);
      expect(promoted.id, caregiver.id);
      expect(promoted.displayName, caregiver.displayName);
      expect(promoted.phone, caregiver.phone);
    });
  });
}

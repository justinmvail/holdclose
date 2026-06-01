import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/care_circle_membership.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/screens/team/care_circle_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

CareCircleMember _member({
  required String id,
  required String displayName,
  required CaregiverRole role,
  required PermissionLevel permission,
  String? phone,
  bool pending = false,
}) =>
    CareCircleMember(
      caregiver: Caregiver(
        id: id,
        displayName: displayName,
        role: role,
        phone: phone,
      ),
      membership: CareCircleMembership(
        id: 'm-$id',
        caregiverId: id,
        patientId: 'demo-patient-mary',
        permissionLevel: permission,
        invitedAt: DateTime.utc(2026, 5, 1),
        acceptedAt: pending ? null : DateTime.utc(2026, 5, 2),
      ),
    );

List<CareCircleMember> _members() => <CareCircleMember>[
      _member(
        id: 'c1',
        displayName: 'Sarah Henderson',
        role: CaregiverRole.child,
        permission: PermissionLevel.owner,
        phone: '555-0100',
      ),
      _member(
        id: 'c2',
        displayName: 'James Henderson',
        role: CaregiverRole.spouse,
        permission: PermissionLevel.editor,
        phone: '555-0123',
      ),
      _member(
        id: 'c3',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
        permission: PermissionLevel.viewer,
        pending: true,
      ),
    ];

Widget _host(List<CareCircleMember> members, double height) {
  return ProviderScope(
    overrides: <Override>[
      careCircleViewProvider.overrideWith(
        (Ref ref) async => CareCircleView(members: members),
      ),
    ],
    child: SizedBox(
      width: 440,
      height: height,
      child: MaterialApp(
        home: const CareCircleScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('CareCircleScreen golden', () {
    goldenTest(
      'renders the populated care circle',
      fileName: 'care_circle_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 14.27)',
            child: _host(_members(), 720),
          ),
        ],
      ),
    );

    goldenTest(
      'renders the empty care circle',
      fileName: 'care_circle_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 14.27)',
            child: _host(const <CareCircleMember>[], 620),
          ),
        ],
      ),
    );
  });
}

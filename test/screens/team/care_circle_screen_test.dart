import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_circle_membership.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/screens/team/care_circle_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

CareCircleMember _member({
  required String id,
  String displayName = 'Sarah Henderson',
  CaregiverRole role = CaregiverRole.child,
  PermissionLevel permission = PermissionLevel.viewer,
  String? phone,
  bool pending = false,
}) {
  return CareCircleMember(
    caregiver: Caregiver(
      id: id,
      displayName: displayName,
      role: role,
      phone: phone,
    ),
    membership: CareCircleMembership(
      id: 'm-$id',
      caregiverId: id,
      patientId: _patientId,
      permissionLevel: permission,
      invitedAt: DateTime.utc(2026, 5, 1),
      acceptedAt: pending ? null : DateTime.utc(2026, 1, 1),
    ),
  );
}

GoRouter _router() {
  return GoRouter(
    initialLocation: '/team/circle',
    routes: <RouteBase>[
      GoRoute(
        path: '/team',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST /team'))),
      ),
      GoRoute(
        path: '/team/circle',
        builder: (BuildContext c, GoRouterState s) => const CareCircleScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'invite',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('DEST invite'))),
          ),
        ],
      ),
    ],
  );
}

Future<(GoRouter, RecordingLinkLauncher)> _pumpView(
  WidgetTester tester, {
  required List<CareCircleMember> members,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final RecordingLinkLauncher launcher = RecordingLinkLauncher();
  final GoRouter router = _router();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        careCircleViewProvider.overrideWith(
          (Ref ref) async => CareCircleView(members: members),
        ),
        linkLauncherProvider.overrideWithValue(launcher),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router, launcher);
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.last.matchedLocation;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CareCircleScreen — display', () {
    testWidgets('empty state shows the share-the-load copy and a CTA',
        (WidgetTester tester) async {
      final (GoRouter router, _) =
          await _pumpView(tester, members: const <CareCircleMember>[]);

      expect(find.byKey(CareCircleScreen.emptyStateKey), findsOneWidget);
      expect(
        find.textContaining('Your care circle is just you right now'),
        findsOneWidget,
      );
      expect(find.byKey(CareCircleScreen.listKey), findsNothing);

      await tester.tap(find.byKey(CareCircleScreen.emptyCtaKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/team/circle/invite');
    });

    testWidgets('populated roster renders name, role chip, permission badge',
        (WidgetTester tester) async {
      await _pumpView(tester, members: <CareCircleMember>[
        _member(
          id: 'c1',
          displayName: 'Sarah Henderson',
          role: CaregiverRole.child,
          permission: PermissionLevel.owner,
        ),
      ]);

      expect(find.byKey(CareCircleScreen.rowKey('c1')), findsOneWidget);
      expect(find.text('Sarah Henderson'), findsOneWidget);
      expect(find.text('Child'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(CareCircleScreen.permissionBadgeKey('c1')),
          matching: find.text('Owner'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a pending invite is badged "Invite pending"',
        (WidgetTester tester) async {
      await _pumpView(tester, members: <CareCircleMember>[
        _member(id: 'c1', pending: true),
      ]);
      expect(find.text('Invite pending'), findsOneWidget);
    });

    testWidgets('call button appears only when a phone is on file, and dials',
        (WidgetTester tester) async {
      final (_, RecordingLinkLauncher launcher) =
          await _pumpView(tester, members: <CareCircleMember>[
        _member(id: 'with', phone: '(555) 010-0200'),
        _member(id: 'without', displayName: 'No Phone'),
      ]);

      expect(find.byKey(CareCircleScreen.callButtonKey('with')), findsOneWidget);
      expect(
          find.byKey(CareCircleScreen.callButtonKey('without')), findsNothing);

      await tester.tap(find.byKey(CareCircleScreen.callButtonKey('with')));
      await tester.pump();
      expect(launcher.launched.single, Uri(scheme: 'tel', path: '5550100200'));
    });

    testWidgets('invite header action pushes the invite route',
        (WidgetTester tester) async {
      final (GoRouter router, _) = await _pumpView(tester,
          members: <CareCircleMember>[_member(id: 'c1')]);

      await tester.tap(find.byKey(CareCircleScreen.inviteActionKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/team/circle/invite');
    });
  });

  group('CareCircleScreen — long-press edit (real repo)', () {
    testWidgets('editing role + permission persists through the notifier',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(440, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final CareblazersDatabase db =
          CareblazersDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final CareCircleRepository repo = CareCircleRepository(db);
      await repo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Sarah Henderson',
        role: CaregiverRole.friend,
      ));
      await repo.upsertMembership(CareCircleMembership(
        id: 'm-c1',
        caregiverId: 'c1',
        patientId: _patientId,
        permissionLevel: PermissionLevel.viewer,
        invitedAt: DateTime.utc(2026, 5, 1),
        acceptedAt: DateTime.utc(2026, 5, 2),
      ));

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            careCircleRepositoryProvider.overrideWithValue(repo),
            careCircleClockProvider.overrideWithValue(
              () => DateTime.utc(2026, 6, 1, 12),
            ),
          ],
          child: MaterialApp.router(routerConfig: _router()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(CareCircleScreen.rowKey('c1')));
      await tester.pumpAndSettle();
      expect(find.byKey(CareCircleScreen.editSheetKey), findsOneWidget);

      await tester
          .tap(find.byKey(CareCircleScreen.editRoleOptionKey(CaregiverRole.aide)));
      await tester.tap(find.byKey(
          CareCircleScreen.editPermissionOptionKey(PermissionLevel.editor)));
      await tester.pump();
      await tester.tap(find.byKey(CareCircleScreen.editSaveKey));
      await tester.pumpAndSettle();

      expect(find.byKey(CareCircleScreen.editSheetKey), findsNothing);
      final Caregiver? caregiver = await repo.getCaregiver('c1');
      final CareCircleMembership? membership = await repo.getMembership('m-c1');
      expect(caregiver!.role, CaregiverRole.aide);
      expect(membership!.permissionLevel, PermissionLevel.editor);
      // The roster reflects the edit.
      expect(find.text('Aide'), findsOneWidget);
    });
  });
}

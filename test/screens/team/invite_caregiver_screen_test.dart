import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_circle_membership.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/share_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/team/invite_caregiver_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Monotonic id/token factory so the minted caregiver id, membership id,
/// and invite token are stable across runs.
InviteIdFactory _counter() {
  int n = 0;
  return () {
    n++;
    return '$n';
  };
}

GoRouter _router() {
  return GoRouter(
    initialLocation: '/team/circle/invite',
    routes: <RouteBase>[
      GoRoute(
        path: '/team/circle',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST circle'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'invite',
            builder: (BuildContext c, GoRouterState s) =>
                const InviteCaregiverScreen(),
          ),
        ],
      ),
    ],
  );
}

Future<(GoRouter, CareCircleRepository, RecordingSharer)> _pump(
  WidgetTester tester, {
  StorageProvider? storage,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final CareCircleRepository repo = CareCircleRepository(db);
  final RecordingSharer sharer = RecordingSharer();
  final GoRouter router = _router();

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        careCircleRepositoryProvider.overrideWithValue(repo),
        storageProvider.overrideWithValue(
          storage ?? InMemoryStorageProvider(),
        ),
        sharerProvider.overrideWithValue(sharer),
        inviteCaregiverIdFactoryProvider.overrideWithValue(_counter()),
        careCircleClockProvider.overrideWithValue(
          () => DateTime.utc(2026, 6, 1, 9),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router, repo, sharer);
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.last.matchedLocation;

Future<void> _tapSend(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(InviteCaregiverScreen.sendButtonKey));
  await tester.tap(find.byKey(InviteCaregiverScreen.sendButtonKey));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InviteCaregiverScreen — validation', () {
    testWidgets('an empty name blocks send and lands no row',
        (WidgetTester tester) async {
      final (GoRouter router, CareCircleRepository repo, _) = await _pump(tester);

      await _tapSend(tester);

      expect(
        find.text('Add a name so you know who you invited.'),
        findsOneWidget,
      );
      expect(await repo.listMemberships(), isEmpty);
      // Still on the form.
      expect(_path(router), '/team/circle/invite');
    });

    testWidgets('a name with no email or phone blocks send and lands no row',
        (WidgetTester tester) async {
      final (_, CareCircleRepository repo, RecordingSharer sharer) =
          await _pump(tester);

      await tester.enterText(
        find.byKey(InviteCaregiverScreen.displayNameFieldKey),
        'Sarah Henderson',
      );
      await _tapSend(tester);

      expect(find.byKey(InviteCaregiverScreen.contactErrorKey), findsOneWidget);
      expect(await repo.listMemberships(), isEmpty);
      expect(sharer.shared, isEmpty);
    });

    testWidgets('a malformed email blocks send', (WidgetTester tester) async {
      final (_, CareCircleRepository repo, _) = await _pump(tester);

      await tester.enterText(
        find.byKey(InviteCaregiverScreen.displayNameFieldKey),
        'Sarah Henderson',
      );
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.emailFieldKey),
        'not-an-email',
      );
      await _tapSend(tester);

      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(await repo.listMemberships(), isEmpty);
    });
  });

  group('InviteCaregiverScreen — send', () {
    testWidgets(
        'a valid invite lands a pending membership, shares the link, and pops',
        (WidgetTester tester) async {
      final (GoRouter router, CareCircleRepository repo, RecordingSharer sharer) =
          await _pump(tester);

      await tester.enterText(
        find.byKey(InviteCaregiverScreen.displayNameFieldKey),
        'Sarah Henderson',
      );
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.emailFieldKey),
        'sarah@example.com',
      );
      await tester.tap(
        find.byKey(InviteCaregiverScreen.roleChipKey(CaregiverRole.child)),
      );
      await tester.pump();
      await _tapSend(tester);

      // The pending row landed.
      final List<CareCircleMembership> memberships =
          await repo.listMemberships();
      expect(memberships, hasLength(1));
      final CareCircleMembership membership = memberships.single;
      expect(membership.acceptedAt, isNull);
      expect(membership.permissionLevel, PermissionLevel.viewer);
      expect(membership.patientId, 'demo-patient-mary');
      expect(membership.invitedAt, DateTime.utc(2026, 6, 1, 9));

      // The caregiver row carries name / role / contact.
      final Caregiver caregiver =
          (await repo.getCaregiver(membership.caregiverId))!;
      expect(caregiver.displayName, 'Sarah Henderson');
      expect(caregiver.role, CaregiverRole.child);
      expect(caregiver.email, 'sarah@example.com');
      expect(caregiver.phone, isNull);

      // The share message carries the invite link with the minted token.
      expect(sharer.shared, hasLength(1));
      expect(
        sharer.shared.single.text,
        'Join my Careblazers care circle: https://careblazers.app/invite/3',
      );

      // Popped back to the roster.
      expect(_path(router), '/team/circle');
    });

    testWidgets('the chosen permission level lands on the membership',
        (WidgetTester tester) async {
      final (_, CareCircleRepository repo, _) = await _pump(tester);

      await tester.enterText(
        find.byKey(InviteCaregiverScreen.displayNameFieldKey),
        'James Henderson',
      );
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.phoneFieldKey),
        '(555) 010-0123',
      );
      await tester.tap(
        find.byKey(
          InviteCaregiverScreen.permissionRadioKey(PermissionLevel.editor),
        ),
      );
      await tester.pump();
      await _tapSend(tester);

      final CareCircleMembership membership =
          (await repo.listMemberships()).single;
      expect(membership.permissionLevel, PermissionLevel.editor);
      final Caregiver caregiver =
          (await repo.getCaregiver(membership.caregiverId))!;
      expect(caregiver.phone, '(555) 010-0123');
      expect(caregiver.email, isNull);
    });
  });
}

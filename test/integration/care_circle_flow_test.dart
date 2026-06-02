/// Integration coverage for the Care Circle membership mutations
/// (BUILD_SPEC.md §5.14 Care Team hub → Care Circle tile → the roster,
/// invite form, and long-press edit sheet), per TASKS.md Phase 15.9.
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15
/// harness (in-memory drift, pinned clock, no-op TTS/analytics, a
/// [FakeUrlLauncher] capturing outbound tel:/mailto: hand-offs) and assert
/// real navigation + drift persistence — never goldens.
///
/// Mary's circle is seeded with two accepted caregivers (a primary owner +
/// a sibling editor) through a [CareCircleRepository] backed by its own
/// in-memory drift, wired in as the [careCircleRepositoryProvider] override
/// so the running roster, the invite form, and the edit sheet all read and
/// write the same store the test asserts against. Five caregiver flows:
///   1. **Invite** — "Invite caregiver" → form → fill name + email + role +
///      permission → Send → a pending membership lands in drift and the
///      [RecordingSharer] captures the composed share message carrying the
///      invite URL.
///   2. **Edit role** — long-press a member → edit sheet → change the role →
///      Save → the caregiver row + the roster chip both reflect it.
///   3. **Edit permission** — long-press → change Editor → Viewer → Save →
///      the membership row + the roster permission badge both update.
///   4. **Remove** — long-press → Remove → confirm → the caregiver (and,
///      cascading, their membership) is dropped from drift and the roster
///      excludes them.
///   5. **Contact actions** — the per-row email + call trailing buttons
///      hand the right `mailto:` / `tel:` URIs to the [FakeUrlLauncher].
library;

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_circle_membership.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/providers/share_provider.dart';
import 'package:careblazers/screens/team/care_circle_screen.dart';
import 'package:careblazers/screens/team/care_team_hub_screen.dart';
import 'package:careblazers/screens/team/invite_caregiver_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

const String _patientId = 'demo-patient-mary';

/// The fixed instant the care-circle clock is pinned to so an invite's
/// `invitedAt` is deterministic.
final DateTime _inviteClock = DateTime.utc(2026, 6, 1, 9);

/// Mary's primary caregiver — accepted, owner, reachable by phone + email.
const Caregiver _primary = Caregiver(
  id: 'cg-sarah',
  displayName: 'Sarah Henderson',
  role: CaregiverRole.primary,
  phone: '(555) 010-0100',
  email: 'sarah@example.com',
);

/// Mary's sibling caregiver — accepted, editor, the member every mutation
/// flow targets so the primary owner row stays put as a control.
const Caregiver _sibling = Caregiver(
  id: 'cg-tom',
  displayName: 'Tom Reyes',
  role: CaregiverRole.sibling,
  phone: '(555) 010-0222',
  email: 'tom@example.com',
);

CareCircleMembership _membership(
  Caregiver caregiver,
  PermissionLevel level,
) =>
    CareCircleMembership(
      id: 'm-${caregiver.id}',
      caregiverId: caregiver.id,
      patientId: _patientId,
      permissionLevel: level,
      invitedAt: DateTime.utc(2026, 5, 1),
      acceptedAt: DateTime.utc(2026, 5, 2),
    );

/// Everything a flow needs to assert against the running circle: the
/// seeded repository (re-read after a mutation) and the recording sharer.
class _Circle {
  _Circle(this.repo, this.sharer);

  final CareCircleRepository repo;
  final RecordingSharer sharer;
}

/// Stand up a [CareCircleRepository] over its own in-memory drift, seed
/// Mary's two accepted caregivers, and return the overrides that wire it
/// (plus a [RecordingSharer] + pinned circle clock + optional invite id
/// factory) into [pumpCareblazersApp]. Seeded before the app pumps so the
/// roster's first load already carries both members.
Future<(_Circle, List<Override>)> _seedCircle(
  WidgetTester tester, {
  InviteIdFactory? idFactory,
}) async {
  final CareblazersDatabase db = CareblazersDatabase.testInstance();
  addTearDown(db.close);
  final CareCircleRepository repo = CareCircleRepository(db);

  await repo.upsertCaregiver(_primary);
  await repo.upsertMembership(_membership(_primary, PermissionLevel.owner));
  await repo.upsertCaregiver(_sibling);
  await repo.upsertMembership(_membership(_sibling, PermissionLevel.editor));

  final RecordingSharer sharer = RecordingSharer();
  final List<Override> overrides = <Override>[
    careCircleRepositoryProvider.overrideWithValue(repo),
    sharerProvider.overrideWithValue(sharer),
    careCircleClockProvider.overrideWithValue(() => _inviteClock),
    if (idFactory != null)
      inviteCaregiverIdFactoryProvider.overrideWithValue(idFactory),
  ];
  return (_Circle(repo, sharer), overrides);
}

/// Monotonic id/token factory so the invite mints `cg-1` / `m-2` and the
/// share token `3` deterministically (matches the invite widget test).
InviteIdFactory _counter() {
  int n = 0;
  return () {
    n++;
    return '$n';
  };
}

void main() {
  group('Care Circle — invite (Phase 15.9)', () {
    testWidgets('Invite caregiver → form → Send lands a pending row + shares',
        (WidgetTester tester) async {
      final (_Circle circle, List<Override> overrides) =
          await _seedCircle(tester, idFactory: _counter());
      await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openCareCircle(tester);

      // Both seeded members are on the roster before the invite.
      expect(find.byKey(CareCircleScreen.rowKey(_primary.id)), findsOneWidget);
      expect(find.byKey(CareCircleScreen.rowKey(_sibling.id)), findsOneWidget);

      await tester.tap(find.byKey(CareCircleScreen.inviteActionKey));
      await tester.pumpAndSettle();
      expect(find.byType(InviteCaregiverScreen), findsOneWidget);

      await tester.enterText(
        find.byKey(InviteCaregiverScreen.displayNameFieldKey),
        'Priya Anand',
      );
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.emailFieldKey),
        'priya@example.com',
      );
      await tester.tap(
        find.byKey(InviteCaregiverScreen.roleChipKey(CaregiverRole.aide)),
      );
      await tester.tap(
        find.byKey(
          InviteCaregiverScreen.permissionRadioKey(PermissionLevel.editor),
        ),
      );
      await tester.pump();

      await tester.ensureVisible(
        find.byKey(InviteCaregiverScreen.sendButtonKey),
      );
      await tester.tap(find.byKey(InviteCaregiverScreen.sendButtonKey));
      await tester.pumpAndSettle();

      // Back on the roster, the new pending member renders.
      expect(find.byType(CareCircleScreen), findsOneWidget);
      expect(find.text('Priya Anand'), findsOneWidget);
      expect(find.text('Invite pending'), findsOneWidget);

      // A third, pending membership landed in drift alongside the two
      // seeded (accepted) ones.
      final List<CareCircleMembership> memberships =
          await circle.repo.listMemberships();
      expect(memberships, hasLength(3));
      final List<CareCircleMembership> pending = memberships
          .where((CareCircleMembership m) => m.acceptedAt == null)
          .toList();
      expect(pending, hasLength(1));
      expect(pending.single.permissionLevel, PermissionLevel.editor);
      expect(pending.single.invitedAt, _inviteClock);

      final Caregiver invited =
          (await circle.repo.getCaregiver(pending.single.caregiverId))!;
      expect(invited.displayName, 'Priya Anand');
      expect(invited.role, CaregiverRole.aide);
      expect(invited.email, 'priya@example.com');

      // The composed share message carries the invite URL with the minted
      // token ('3' under the monotonic factory).
      expect(circle.sharer.shared, hasLength(1));
      expect(
        circle.sharer.shared.single.text,
        'Join my Careblazers care circle: https://careblazers.app/invite/3',
      );

      await _flushTimers(tester);
    });
  });

  group('Care Circle — edit role (Phase 15.9)', () {
    testWidgets('long-press → change role → Save updates drift + roster',
        (WidgetTester tester) async {
      final (_Circle circle, List<Override> overrides) =
          await _seedCircle(tester);
      await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openCareCircle(tester);

      // Tom starts as a Sibling.
      expect(find.text('Sibling'), findsOneWidget);

      await _openEditSheet(tester, _sibling.id);
      await tester.tap(
        find.byKey(CareCircleScreen.editRoleOptionKey(CaregiverRole.aide)),
      );
      await tester.pump();
      await tester.tap(find.byKey(CareCircleScreen.editSaveKey));
      await tester.pumpAndSettle();

      // Sheet dismissed; the roster chip + the drift row both read Aide.
      expect(find.byKey(CareCircleScreen.editSheetKey), findsNothing);
      expect(find.text('Aide'), findsOneWidget);
      expect(find.text('Sibling'), findsNothing);

      final Caregiver updated = (await circle.repo.getCaregiver(_sibling.id))!;
      expect(updated.role, CaregiverRole.aide);

      await _flushTimers(tester);
    });
  });

  group('Care Circle — edit permission (Phase 15.9)', () {
    testWidgets('long-press → Editor → Viewer → Save updates drift + roster',
        (WidgetTester tester) async {
      final (_Circle circle, List<Override> overrides) =
          await _seedCircle(tester);
      await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openCareCircle(tester);

      // Tom's badge starts as Editor.
      expect(
        find.descendant(
          of: find.byKey(CareCircleScreen.permissionBadgeKey(_sibling.id)),
          matching: find.text('Editor'),
        ),
        findsOneWidget,
      );

      await _openEditSheet(tester, _sibling.id);
      await tester.tap(
        find.byKey(
          CareCircleScreen.editPermissionOptionKey(PermissionLevel.viewer),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(CareCircleScreen.editSaveKey));
      await tester.pumpAndSettle();

      // The roster badge now reads Viewer and the membership row persisted.
      expect(
        find.descendant(
          of: find.byKey(CareCircleScreen.permissionBadgeKey(_sibling.id)),
          matching: find.text('Viewer'),
        ),
        findsOneWidget,
      );
      final CareCircleMembership membership =
          (await circle.repo.getMembership('m-${_sibling.id}'))!;
      expect(membership.permissionLevel, PermissionLevel.viewer);

      await _flushTimers(tester);
    });
  });

  group('Care Circle — remove member (Phase 15.9)', () {
    testWidgets('long-press → Remove → confirm drops the row from drift',
        (WidgetTester tester) async {
      final (_Circle circle, List<Override> overrides) =
          await _seedCircle(tester);
      await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openCareCircle(tester);

      expect(find.byKey(CareCircleScreen.rowKey(_sibling.id)), findsOneWidget);

      await _openEditSheet(tester, _sibling.id);
      await tester.tap(find.byKey(CareCircleScreen.editRemoveKey));
      await tester.pumpAndSettle();

      // The confirmation dialog gates the destructive action.
      expect(find.text('Remove Tom Reyes?'), findsOneWidget);
      await tester.tap(find.byKey(CareCircleScreen.removeConfirmKey));
      await tester.pumpAndSettle();

      // The sheet closed and Tom is gone from the roster; Sarah remains.
      expect(find.byKey(CareCircleScreen.editSheetKey), findsNothing);
      expect(find.byKey(CareCircleScreen.rowKey(_sibling.id)), findsNothing);
      expect(find.byKey(CareCircleScreen.rowKey(_primary.id)), findsOneWidget);

      // The caregiver and (cascading) their membership are gone from drift.
      expect(await circle.repo.getCaregiver(_sibling.id), isNull);
      expect(await circle.repo.getMembership('m-${_sibling.id}'), isNull);
      final List<CareCircleMembership> remaining =
          await circle.repo.listMemberships();
      expect(remaining, hasLength(1));
      expect(remaining.single.caregiverId, _primary.id);

      await _flushTimers(tester);
    });
  });

  group('Care Circle — contact actions (Phase 15.9)', () {
    testWidgets('email + call trailing buttons launch mailto: / tel: URIs',
        (WidgetTester tester) async {
      final (_, List<Override> overrides) = await _seedCircle(tester);
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openCareCircle(tester);

      final FakeUrlLauncher launcher =
          container.read(linkLauncherProvider) as FakeUrlLauncher;

      await tester.tap(find.byKey(CareCircleScreen.emailButtonKey(_primary.id)));
      await tester.pump();
      expect(launcher.lastLaunched, Uri(scheme: 'mailto', path: 'sarah@example.com'));

      await tester.tap(find.byKey(CareCircleScreen.callButtonKey(_primary.id)));
      await tester.pump();
      expect(launcher.lastLaunched, Uri(scheme: 'tel', path: '5550100100'));

      expect(launcher.launched, hasLength(2));

      await _flushTimers(tester);
    });
  });
}

// ---------------------------------------------------------------------------
// Navigation + interaction helpers
// ---------------------------------------------------------------------------

/// Home → Team tab → Care Circle tile → [CareCircleScreen].
Future<void> _openCareCircle(WidgetTester tester) async {
  await tester.tap(tabFor('Team'));
  await tester.pumpAndSettle();
  expect(find.byType(CareTeamHubScreen), findsOneWidget);

  await tester.tap(findHubTile('Care Circle'));
  await tester.pumpAndSettle();
  expect(find.byType(CareCircleScreen), findsOneWidget);
}

/// Long-press the roster row for [caregiverId] and wait for the edit sheet.
Future<void> _openEditSheet(WidgetTester tester, String caregiverId) async {
  await tester.longPress(find.byKey(CareCircleScreen.rowKey(caregiverId)));
  await tester.pumpAndSettle();
  expect(find.byKey(CareCircleScreen.editSheetKey), findsOneWidget);
}

/// Grow the surface so the lazy form ListView (the invite fields below the
/// fold) and the full-height edit bottom sheet (role + permission chip
/// groups, Save, and Remove) build and stay tappable. The harness teardown
/// resets the surface to null.
Future<void> _grow(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(560, 1800));
  await tester.pumpAndSettle();
}

/// Drain Home's still-mounted bare-timer streams (e.g. the "catch me up"
/// recap) so none outlive the test and trip flutter_test's "Timer still
/// pending" invariant — mirrors the Phase 15.7 flow's flush.
Future<void> _flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

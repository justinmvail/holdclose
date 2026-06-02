/// Integration coverage for the Care Circle invite *form validation*
/// (BUILD_SPEC.md §5.14 Care Team hub → Care Circle tile → invite form),
/// per TASKS.md Phase 15.10. Companion to the Phase 15.9 mutation flow
/// ([care_circle_flow_test.dart]) — that one proves a valid invite lands a
/// pending row + shares; this one proves the guardrails around it.
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15 harness
/// (in-memory drift, pinned clock, no-op TTS/analytics, a [RecordingSharer]
/// capturing outbound share hand-offs) and assert real navigation + drift
/// persistence (never goldens). The circle starts empty so a membership
/// count is an unambiguous "did the invite land?" signal: a blocked or
/// abandoned invite leaves drift at zero, a successful one at exactly one.
///
/// Five validation flows:
///   1. **Empty name** — Send with a blank display name surfaces the inline
///      "name required" error and lands no row.
///   2. **No contact** — a named invite with neither email nor phone
///      surfaces the cross-field "at least one contact" error and lands no
///      row.
///   3. **Malformed email** — a named invite with a bad email surfaces the
///      field-level email error and lands no row.
///   4. **Rapid double-tap** — a valid invite double-tapped on Send lands
///      *exactly one* pending membership (the submit guard de-dupes).
///   5. **Back, not Send** — leaving the form via the PathHeader Back
///      control lands no row even with every field filled.
library;

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_circle_membership.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/share_provider.dart';
import 'package:careblazers/screens/team/care_circle_screen.dart';
import 'package:careblazers/screens/team/care_team_hub_screen.dart';
import 'package:careblazers/screens/team/invite_caregiver_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

/// The fixed instant the care-circle clock is pinned to so any invite that
/// *did* land would carry a deterministic `invitedAt`.
final DateTime _inviteClock = DateTime.utc(2026, 6, 1, 9);

/// Everything a flow asserts against: the (initially empty) repository —
/// re-read after the attempt — and the recording sharer.
class _Circle {
  _Circle(this.repo, this.sharer);

  final CareCircleRepository repo;
  final RecordingSharer sharer;
}

/// Stand up a [CareCircleRepository] over its own in-memory drift — left
/// empty so the roster opens on its empty state and a membership count is a
/// clean signal — and return the overrides that wire it (plus a
/// [RecordingSharer], the pinned circle clock, and a monotonic invite id
/// factory) into [pumpCareblazersApp].
Future<(_Circle, List<Override>)> _seedEmptyCircle(WidgetTester tester) async {
  final CareblazersDatabase db = CareblazersDatabase.testInstance();
  addTearDown(db.close);
  final CareCircleRepository repo = CareCircleRepository(db);

  final RecordingSharer sharer = RecordingSharer();
  final List<Override> overrides = <Override>[
    careCircleRepositoryProvider.overrideWithValue(repo),
    sharerProvider.overrideWithValue(sharer),
    careCircleClockProvider.overrideWithValue(() => _inviteClock),
    inviteCaregiverIdFactoryProvider.overrideWithValue(_counter()),
  ];
  return (_Circle(repo, sharer), overrides);
}

/// Monotonic id/token factory so any minted ids/token are stable across
/// runs (matches the Phase 15.9 flow + the invite widget test).
InviteIdFactory _counter() {
  int n = 0;
  return () {
    n++;
    return '$n';
  };
}

void main() {
  group('Care Circle invite validation (Phase 15.10)', () {
    testWidgets('empty display name surfaces the inline error and lands no row',
        (WidgetTester tester) async {
      final (_Circle circle, List<Override> overrides) =
          await _seedEmptyCircle(tester);
      await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openInviteForm(tester);

      // Fill a contact but leave the name blank, then try to send.
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.emailFieldKey),
        'priya@example.com',
      );
      await _tapSend(tester);

      // The name field's own validator fires; we never leave the form.
      expect(find.byType(InviteCaregiverScreen), findsOneWidget);
      expect(
        find.text('Add a name so you know who you invited.'),
        findsOneWidget,
      );

      // Nothing persisted, nothing shared.
      expect(await circle.repo.listMemberships(), isEmpty);
      expect(await circle.repo.listCaregivers(), isEmpty);
      expect(circle.sharer.shared, isEmpty);

      await _flushTimers(tester);
    });

    testWidgets('empty email AND phone surfaces the contact error, no row',
        (WidgetTester tester) async {
      final (_Circle circle, List<Override> overrides) =
          await _seedEmptyCircle(tester);
      await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openInviteForm(tester);

      // A name but no contact point at all.
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.displayNameFieldKey),
        'Priya Anand',
      );
      await _tapSend(tester);

      // The cross-field "at least one contact" rule blocks the send.
      expect(find.byType(InviteCaregiverScreen), findsOneWidget);
      expect(
        find.byKey(InviteCaregiverScreen.contactErrorKey),
        findsOneWidget,
      );

      expect(await circle.repo.listMemberships(), isEmpty);
      expect(await circle.repo.listCaregivers(), isEmpty);
      expect(circle.sharer.shared, isEmpty);

      await _flushTimers(tester);
    });

    testWidgets('a malformed email surfaces the field-level error, no row',
        (WidgetTester tester) async {
      final (_Circle circle, List<Override> overrides) =
          await _seedEmptyCircle(tester);
      await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openInviteForm(tester);

      await tester.enterText(
        find.byKey(InviteCaregiverScreen.displayNameFieldKey),
        'Priya Anand',
      );
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.emailFieldKey),
        'not-an-email',
      );
      await _tapSend(tester);

      expect(find.byType(InviteCaregiverScreen), findsOneWidget);
      expect(find.text('Enter a valid email address.'), findsOneWidget);

      expect(await circle.repo.listMemberships(), isEmpty);
      expect(await circle.repo.listCaregivers(), isEmpty);
      expect(circle.sharer.shared, isEmpty);

      await _flushTimers(tester);
    });

    testWidgets('rapid double-tap on Send lands exactly one pending membership',
        (WidgetTester tester) async {
      final (_Circle circle, List<Override> overrides) =
          await _seedEmptyCircle(tester);
      await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openInviteForm(tester);

      await tester.enterText(
        find.byKey(InviteCaregiverScreen.displayNameFieldKey),
        'Priya Anand',
      );
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.emailFieldKey),
        'priya@example.com',
      );

      // Two taps dispatched back-to-back with no pump between them, so the
      // button never rebuilds to its disabled state in the gap — only the
      // submit guard stands between the second tap and a duplicate row.
      await tester.ensureVisible(
        find.byKey(InviteCaregiverScreen.sendButtonKey),
      );
      await tester.tap(find.byKey(InviteCaregiverScreen.sendButtonKey));
      await tester.tap(find.byKey(InviteCaregiverScreen.sendButtonKey));
      await tester.pumpAndSettle();

      // Back on the roster with the single pending member rendered.
      expect(find.byType(CareCircleScreen), findsOneWidget);
      expect(find.text('Priya Anand'), findsOneWidget);
      expect(find.text('Invite pending'), findsOneWidget);

      // Exactly one membership + one caregiver landed in drift — the guard
      // de-duped the second tap.
      final List<CareCircleMembership> memberships =
          await circle.repo.listMemberships();
      expect(memberships, hasLength(1));
      expect(memberships.single.acceptedAt, isNull);
      expect(memberships.single.invitedAt, _inviteClock);
      expect(await circle.repo.listCaregivers(), hasLength(1));

      // And the link was composed once, not twice.
      expect(circle.sharer.shared, hasLength(1));

      await _flushTimers(tester);
    });

    testWidgets('leaving via Back lands no row even with a full form',
        (WidgetTester tester) async {
      final (_Circle circle, List<Override> overrides) =
          await _seedEmptyCircle(tester);
      await pumpCareblazersApp(tester, extraOverrides: overrides);
      await _grow(tester);
      await _openInviteForm(tester);

      // Fill every field so the only thing standing between this form and a
      // landed row is the choice of Back over Send.
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.displayNameFieldKey),
        'Priya Anand',
      );
      await tester.enterText(
        find.byKey(InviteCaregiverScreen.emailFieldKey),
        'priya@example.com',
      );

      // The PathHeader word-labeled Back control, not Send.
      await tester.ensureVisible(pathHeaderBackTo('Care Circle'));
      await tester.tap(pathHeaderBackTo('Care Circle'));
      await tester.pumpAndSettle();

      // Back on the roster, still on its empty state — nothing persisted or
      // shared.
      expect(find.byType(CareCircleScreen), findsOneWidget);
      expect(find.byKey(CareCircleScreen.emptyStateKey), findsOneWidget);
      expect(await circle.repo.listMemberships(), isEmpty);
      expect(await circle.repo.listCaregivers(), isEmpty);
      expect(circle.sharer.shared, isEmpty);

      await _flushTimers(tester);
    });
  });
}

// ---------------------------------------------------------------------------
// Navigation + interaction helpers
// ---------------------------------------------------------------------------

/// Home → Team tab → Care Circle tile → "Invite caregiver" →
/// [InviteCaregiverScreen].
Future<void> _openInviteForm(WidgetTester tester) async {
  await tester.tap(tabFor('Team'));
  await tester.pumpAndSettle();
  expect(find.byType(CareTeamHubScreen), findsOneWidget);

  await tester.tap(findHubTile('Care Circle'));
  await tester.pumpAndSettle();
  expect(find.byType(CareCircleScreen), findsOneWidget);

  await tester.tap(find.byKey(CareCircleScreen.inviteActionKey));
  await tester.pumpAndSettle();
  expect(find.byType(InviteCaregiverScreen), findsOneWidget);
}

/// Scroll the Send button into view (it sits below the fold in the form's
/// ListView) and tap it, then settle.
Future<void> _tapSend(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(InviteCaregiverScreen.sendButtonKey));
  await tester.tap(find.byKey(InviteCaregiverScreen.sendButtonKey));
  await tester.pumpAndSettle();
}

/// Grow the surface so the lazy form ListView (the invite fields + the Send
/// button below the fold) builds and stays tappable. The harness teardown
/// resets the surface to null. Mirrors the Phase 15.9 flow's `_grow`.
Future<void> _grow(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(560, 1800));
  await tester.pumpAndSettle();
}

/// Drain Home's still-mounted bare-timer streams (e.g. the "catch me up"
/// recap) so none outlive the test and trip flutter_test's "Timer still
/// pending" invariant — mirrors the Phase 15.9 flow's flush.
Future<void> _flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

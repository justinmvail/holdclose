/// Integration coverage for the appointment CRUD flow (BUILD_SPEC.md
/// §5.13 Medical hub → Appointments tile → the list / form / detail
/// screens), per TASKS.md Phase 15.7.
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15
/// harness (in-memory drift, pinned clock, no-op TTS/analytics/
/// notifications) and assert real navigation + drift persistence — never
/// goldens. Five caregiver flows:
///   1. **Empty state** — Medical → Appointments on a fresh app shows the
///      list's single empty body (no Upcoming / Past section headers, no
///      FAB). The screen renders ONE combined empty state rather than a
///      per-section one, so the test asserts the unified copy + the
///      absence of both section headers.
///   2. **Add** — empty list → "Add an appointment" CTA → fill provider +
///      date + time + location + notes → Save → the new row appears under
///      the "Upcoming" header and a real drift [Appointment] is written.
///      Once the list is non-empty the floating "Add appointment" FAB is
///      the same entry point, asserted present after the add.
///   3. **View + edit** — tap a row → [AppointmentDetailScreen] renders
///      every field → open the edit form (pre-filled) → change the time →
///      Save → the detail screen shows the new time. The detail screen
///      ships no Edit affordance of its own (the `/appointments/:id/edit`
///      route is reachable only programmatically), so — mirroring the
///      Phase 15.6 dose-log flow's programmatic `pushNamed` — the test
///      pushes the edit route through the production router.
///   4. **Past section** — an `upcoming`-status appointment whose
///      `startsAt` has already slipped past "now" lands in the "Past"
///      section, not "Upcoming" (the repository's [AppointmentRepository.past]
///      predicate), verified at both the UI and the data layer.
///   5. **Home cross-screen sync** — with appointments on the books, the
///      Home Schedule card surfaces the soonest upcoming visit under the
///      "Today" section (it falls within today's calendar day against
///      the pinned harness clock) and a later-week visit under "This
///      week". Both rows are tappable.
///
/// The harness pins every clock to [kHarnessClock] (2026-06-01 11:00) and
/// now also shares its in-memory db with the [ProviderRepository] seam so
/// provider names round-trip. Each test additionally supplies
/// [_formOverrides]: a pinned form clock (so the default `startsAt` slot
/// is deterministic) and a monotonic id factory (so the minted
/// appointment id is `appt-id0`).
library;

import 'dart:async';

import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/appointment/appointment_detail_screen.dart';
import 'package:careblazers/screens/appointment/appointment_form_screen.dart';
import 'package:careblazers/screens/appointment/appointment_list_screen.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:careblazers/providers/patient_timeline_provider.dart';
import 'package:careblazers/widgets/home/schedule_card.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:flutter/material.dart';
// `Provider` in [models/appointment.dart] collides with riverpod's own
// `Provider` class — `hide` keeps the model name resolvable here without
// aliasing every callsite, the same way the appointment screens do.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

/// The appointment id the add-form mints under the monotonic id factory
/// (`appt-${mint()}` with the first `mint()` → `id0`). Selecting an
/// existing provider mints nothing, so the appointment takes the first id.
const String _addedApptId = 'appt-id0';

/// The healthcare provider every flow seeds so the form dropdown has a
/// row to pick and the list/detail/home surfaces have a name to resolve.
const Provider _ortega = Provider(
  id: 'prov-ortega',
  name: 'Dr. Ortega',
  role: ProviderRole.neurologist,
  phone: '(415) 555-0188',
  address: '250 Bon Air Rd, Greenbrae CA',
);

/// Pin the appointment form's clock + id factory so the minted
/// appointment id and the default `startsAt` slot are deterministic. A
/// fresh monotonic counter per call ('id0', 'id1', …); the add path takes
/// `appt-id0` for the appointment when an existing provider is selected.
///
/// Also stubs the two patient-timeline sources the shared harness leaves
/// unwired — `patientHealthLogEvents` and `patientCarePlanEvents` —
/// straight to empty (the sanctioned "override each source via the
/// existing per-source providers" seam on [patientTimelineEvents]).
/// Their backends call `CareblazersDatabase.open()` (the real on-disk
/// handle), which never resolves under `flutter test`, so the Home
/// Schedule card's `patientTimelineEvents` watch would otherwise hang in
/// its loading skeleton and the seeded appointments never render. None of
/// these flows seed health-log or care-plan rows, so empty is the same
/// value a correctly-wired merger would produce — only the appointment
/// projection (read through the harness's in-memory repo) carries data.
List<Override> _formOverrides() {
  int counter = 0;
  return <Override>[
    appointmentFormClockProvider.overrideWithValue(() => kHarnessClock),
    appointmentFormIdFactoryProvider.overrideWithValue(() => 'id${counter++}'),
    patientHealthLogEventsProvider
        .overrideWith((Ref ref) async => const <CareEvent>[]),
    patientCarePlanEventsProvider
        .overrideWith((Ref ref) async => const <CareEvent>[]),
  ];
}

void main() {
  // The "Add appointment" affordances share a process-wide debounce
  // (the duplicate-appointment guard) that drops a rapid second tap.
  // Reset it before each case so one test's add tap doesn't suppress the
  // next test's.
  setUp(appointmentAddDebounce.reset);

  group('Appointment CRUD — empty state (Phase 15.7)', () {
    testWidgets('Medical → Appointments shows the empty body, no sections',
        (WidgetTester tester) async {
      await pumpCareblazersApp(tester, extraOverrides: _formOverrides());

      await _openAppointmentList(tester);

      // The list renders a single combined empty state — there is no
      // per-section empty copy, so neither the "Upcoming" nor the "Past"
      // header is present, and no FAB until there is something to add.
      expect(find.byKey(AppointmentListScreen.emptyStateKey), findsOneWidget);
      expect(find.text('No appointments yet.'), findsOneWidget);
      expect(
          find.byKey(AppointmentListScreen.upcomingSectionKey), findsNothing);
      expect(find.byKey(AppointmentListScreen.pastSectionKey), findsNothing);
      expect(find.byKey(AppointmentListScreen.fabKey), findsNothing);

      await _flushTimers(tester);
    });
  });

  group('Appointment CRUD — add an appointment (Phase 15.7)', () {
    testWidgets('empty list → form → Save writes the row into Upcoming',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _formOverrides());
      await _useWideSurface(tester);
      await container.read(providerRepositoryBackendProvider)
          .upsertProvider(_ortega);

      await _openAppointmentList(tester);
      expect(find.byKey(AppointmentListScreen.emptyStateKey), findsOneWidget);

      // The empty-state CTA opens the same form the FAB reaches once the
      // list is populated.
      await _tap(tester, AppointmentListScreen.emptyCtaKey);
      expect(find.byType(AppointmentFormScreen), findsOneWidget);
      // The form's header is now a PathHeader (Home › Medical › Appointments
      // › Add appointment) rather than an AppBar — assert the add-mode title
      // on the header itself. (The text repeats in the header as both the
      // title row and the terminal breadcrumb crumb, so match the
      // PathHeader.title property directly instead of by descendant text.)
      expect(_pathHeaderWithTitle('Add appointment'), findsOneWidget);

      // Provider — pick the seeded row from the dropdown.
      await tester.tap(find.byKey(AppointmentFormScreen.providerDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dr. Ortega').last);
      await tester.pumpAndSettle();

      // Date + time — confirm the form's default slot through the real
      // pickers (the slot is deterministic under the pinned form clock:
      // one week out at the next round hour → 2026-06-08 12:00).
      await _confirmPicker(tester, AppointmentFormScreen.dateFieldKey);
      await _confirmPicker(tester, AppointmentFormScreen.timeFieldKey);

      // Location (overrides the provider-address auto-fill) + notes.
      await _enterText(
        tester,
        AppointmentFormScreen.locationFieldKey,
        'Marin General — Neurology, Suite 200',
      );
      await _enterText(
        tester,
        AppointmentFormScreen.notesFieldKey,
        'Bring the journal and the med list.',
      );

      await _tap(tester, AppointmentFormScreen.submitButtonKey);

      // Back on the list: the new row sits under the "Upcoming" header and
      // the FAB is now the add entry point.
      expect(find.byType(AppointmentListScreen), findsOneWidget);
      expect(
          find.byKey(AppointmentListScreen.upcomingSectionKey), findsOneWidget);
      expect(find.byKey(AppointmentListScreen.cardKey(_addedApptId)),
          findsOneWidget);
      expect(find.text('Dr. Ortega'), findsOneWidget);
      expect(find.byKey(AppointmentListScreen.fabKey), findsOneWidget);

      // The drift row was written — re-read straight from the repository.
      final Appointment? saved = await container
          .read(appointmentRepositoryBackendProvider)
          .getAppointment(_addedApptId);
      expect(saved, isNotNull);
      expect(saved!.providerId, _ortega.id);
      expect(saved.location, 'Marin General — Neurology, Suite 200');
      expect(saved.notes, 'Bring the journal and the med list.');
      expect(saved.status, AppointmentStatus.upcoming);
      // …and it is genuinely upcoming relative to the pinned clock.
      expect(saved.startsAt.isAfter(kHarnessClock), isTrue);

      await _flushTimers(tester);
    });
  });

  group('Appointment CRUD — view + edit (Phase 15.7)', () {
    testWidgets('tap row → detail renders → edit the time → detail updates',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _formOverrides());
      await _useWideSurface(tester);
      await _seedProvider(container);
      await _seedAppointment(
        container,
        const _ApptSeed(
          id: 'appt-edit',
          // 2026-06-08 14:30 → "2:30 PM" before the edit.
          startsAt: _Instant(2026, 6, 8, 14, 30),
          location: 'Marin Neurology',
          agenda: <String>['Ask about evening agitation'],
          notes: 'Bring the journal.',
        ),
      );

      await _openAppointmentList(tester);
      await _tap(tester, AppointmentListScreen.cardKey('appt-edit'));

      // The detail screen renders every field.
      expect(find.byType(AppointmentDetailScreen), findsOneWidget);
      expect(find.text('Dr. Ortega'), findsOneWidget);
      expect(find.text('2:30 PM'), findsOneWidget);
      expect(find.text('Marin Neurology'), findsOneWidget);
      expect(find.text('Ask about evening agitation'), findsOneWidget);
      expect(find.text('Bring the journal.'), findsOneWidget);

      // Open the edit form (no on-screen Edit button — pushed through the
      // production router, like the Phase 15.6 dose-log programmatic push).
      unawaited(container
          .read(careblazersRouterProvider)
          .push('/appointments/appt-edit/edit'));
      await tester.pumpAndSettle();
      expect(find.byType(AppointmentFormScreen), findsOneWidget);
      // Edit-mode header is the PathHeader (… › Appointments › Edit
      // appointment), not an AppBar. Match PathHeader.title directly — the
      // label also repeats in the terminal breadcrumb crumb.
      expect(_pathHeaderWithTitle('Edit appointment'), findsOneWidget);
      // Pre-filled from the saved row — the location field hydrated from
      // the persisted appointment (the lower notes field sits below the
      // fold in the lazy form ListView, so location is the in-view proof).
      expect(find.text('Marin Neurology'), findsOneWidget);

      // Change the time 2:30 PM → 3:15 PM and save.
      await _setTime(tester, hour12: 3, minute: 15, pm: true);
      await _tap(tester, AppointmentFormScreen.submitButtonKey);

      // Back on the detail screen, the new time is shown and the old one
      // is gone.
      expect(find.byType(AppointmentDetailScreen), findsOneWidget);
      expect(find.text('3:15 PM'), findsOneWidget);
      expect(find.text('2:30 PM'), findsNothing);

      // The drift row carries the new time; the id was reused, not minted.
      final Appointment? saved = await container
          .read(appointmentRepositoryBackendProvider)
          .getAppointment('appt-edit');
      expect(saved, isNotNull);
      expect(saved!.startsAt.hour, 15);
      expect(saved.startsAt.minute, 15);

      await _flushTimers(tester);
    });
  });

  group('Appointment CRUD — past section (Phase 15.7)', () {
    testWidgets('an upcoming-status visit in the past lands under "Past"',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _formOverrides());
      await _seedProvider(container);
      await _seedAppointment(
        container,
        const _ApptSeed(
          id: 'appt-past',
          // 2026-05-28 10:00 — before the pinned "now" (2026-06-01 11:00).
          startsAt: _Instant(2026, 5, 28, 10, 0),
          location: 'Marin Neurology',
        ),
      );

      await _openAppointmentList(tester);

      // The row renders under the "Past" header; "Upcoming" never appears.
      expect(find.byKey(AppointmentListScreen.pastSectionKey), findsOneWidget);
      expect(
          find.byKey(AppointmentListScreen.upcomingSectionKey), findsNothing);
      expect(find.byKey(AppointmentListScreen.cardKey('appt-past')),
          findsOneWidget);

      // Data layer agrees: the repo's past/upcoming split places it in
      // past, not upcoming.
      final AppointmentRepository repo =
          container.read(appointmentRepositoryBackendProvider);
      final List<Appointment> past = await repo.past();
      final List<Appointment> upcoming = await repo.upcoming();
      expect(past.map((Appointment a) => a.id), contains('appt-past'));
      expect(upcoming.map((Appointment a) => a.id), isNot(contains('appt-past')));

      await _flushTimers(tester);
    });
  });

  group('Appointment CRUD — Home cross-screen sync (Phase 15.7)', () {
    testWidgets('Schedule card surfaces today + tomorrow visits',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _formOverrides());
      await _seedProvider(container);
      // A later visit (no driver) + a sooner one. Both must surface on
      // the Schedule card — the sooner one under "Today", the later one
      // under "Tomorrow" — rather than the single Next Appointment row
      // the old card showed.
      await _seedAppointment(
        container,
        const _ApptSeed(
          id: 'appt-later',
          // 2026-06-02 09:00 — tomorrow against the pinned harness clock
          // (Mon 2026-06-01). Falls under "Tomorrow".
          startsAt: _Instant(2026, 6, 2, 9, 0),
          location: 'Marin Neurology',
        ),
      );
      await _seedAppointment(
        container,
        const _ApptSeed(
          id: 'appt-soon',
          // 2026-06-01 14:00 → today against the pinned clock.
          startsAt: _Instant(2026, 6, 1, 14, 0),
          location: 'Marin Neurology',
          driverName: 'Marcus Bell',
        ),
      );

      // Home was built empty at pump; invalidate the timeline merger so
      // the still-mounted Schedule card re-reads the seeded rows.
      container.invalidate(patientTimelineEventsProvider);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(ScheduleCard.cardKey));
      await tester.pumpAndSettle();

      // Both sections + both rows render.
      expect(find.byKey(ScheduleCard.todaySectionKey), findsOneWidget);
      expect(find.byKey(ScheduleCard.tomorrowSectionKey), findsOneWidget);
      expect(
        find.byKey(ScheduleCard.rowKey('appt-appt-soon')),
        findsOneWidget,
      );
      expect(
        find.byKey(ScheduleCard.rowKey('appt-appt-later')),
        findsOneWidget,
      );

      await _flushTimers(tester);
    });
  });
}

// ---------------------------------------------------------------------------
// Seeding
// ---------------------------------------------------------------------------

/// A compile-time-constructible appointment fixture — freezed's
/// [Appointment] takes a [DateTime] (not const), so the seed carries an
/// [_Instant] and builds the model at seed time.
@immutable
class _ApptSeed {
  const _ApptSeed({
    required this.id,
    required this.startsAt,
    required this.location,
    this.agenda = const <String>[],
    this.notes,
    this.driverName,
  });

  final String id;
  final _Instant startsAt;
  final String location;
  final List<String> agenda;
  final String? notes;
  final String? driverName;

  Appointment toModel() => Appointment(
        id: id,
        providerId: _ortega.id,
        startsAt: startsAt.toDateTime(),
        durationMinutes: 30,
        location: location,
        agenda: agenda,
        status: AppointmentStatus.upcoming,
        notes: notes,
        driverName: driverName,
      );
}

/// A const-friendly wall-clock instant the seed fixtures carry until a
/// [DateTime] is materialised at seed time.
@immutable
class _Instant {
  const _Instant(this.year, this.month, this.day, this.hour, this.minute);

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;

  DateTime toDateTime() => DateTime(year, month, day, hour, minute);
}

Future<void> _seedProvider(ProviderContainer container) =>
    container.read(providerRepositoryBackendProvider).upsertProvider(_ortega);

Future<void> _seedAppointment(ProviderContainer container, _ApptSeed seed) =>
    container
        .read(appointmentRepositoryBackendProvider)
        .upsertAppointment(seed.toModel());

// ---------------------------------------------------------------------------
// Navigation + interaction helpers
// ---------------------------------------------------------------------------

/// The [PathHeader] whose [PathHeader.title] equals [title] — the
/// AppBar-free replacement for the old `widgetWithText(AppBar, …)` title
/// check. Matching the title property (rather than descendant text) keeps
/// the assertion to exactly one widget even though the form's header
/// repeats the label in its terminal breadcrumb crumb, and even with the
/// list screen's own PathHeader still mounted beneath the pushed form.
Finder _pathHeaderWithTitle(String title) => find.byWidgetPredicate(
      (Widget w) => w is PathHeader && w.title == title,
    );

/// Grow the test surface before driving the date/time pickers. The
/// material date picker dialog is wider than the harness's default
/// 420-wide surface (its "OK" action lands off the right edge and the tap
/// misses), and the taller viewport builds more of the form's lazy
/// ListView. The harness's own teardown resets the surface to null.
Future<void> _useWideSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  await tester.pumpAndSettle();
}

/// Home → Care tab → Appointments tile → [AppointmentListScreen].
Future<void> _openAppointmentList(WidgetTester tester) async {
  await tester.tap(tabFor('Care'));
  await tester.pumpAndSettle();
  expect(find.byType(MedicalHubScreen), findsOneWidget);

  await tester.tap(findHubTile('Appointments'));
  await tester.pumpAndSettle();
  expect(find.byType(AppointmentListScreen), findsOneWidget);
}

/// Open the date/time picker behind [fieldKey] and accept the shown value
/// (the deterministic default under the pinned form clock).
Future<void> _confirmPicker(WidgetTester tester, Key fieldKey) async {
  await _tap(tester, fieldKey);
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

/// Drive the time picker to [hour12]:[minute] [pm? PM : AM] via its
/// text-input mode — robust against the dial's tap-coordinate math.
Future<void> _setTime(
  WidgetTester tester, {
  required int hour12,
  required int minute,
  required bool pm,
}) async {
  await _tap(tester, AppointmentFormScreen.timeFieldKey);
  await tester.tap(find.byTooltip('Switch to text input mode'));
  await tester.pumpAndSettle();

  // Input mode renders the hour field then the minute field inside the
  // picker's Dialog — scope to the dialog so the form's own TextFields
  // underneath the modal aren't matched.
  final Finder fields = find.descendant(
    of: find.byType(Dialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(fields.at(0), '$hour12');
  await tester.enterText(fields.at(1), minute.toString().padLeft(2, '0'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(pm ? 'PM' : 'AM'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

/// Scroll [key] into view then enter [text] + settle.
Future<void> _enterText(WidgetTester tester, Key key, String text) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(key), text);
  await tester.pumpAndSettle();
}

/// Scroll [key] into view (form rows + Save can sit below the fold on the
/// harness's 420×900 surface) then tap + settle.
Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// Drain any bare-timer streams (e.g. Home's still-mounted "catch me up"
/// recap) so none outlive the test and trip flutter_test's "Timer still
/// pending" invariant — mirrors the Phase 15.6 flow's recap flush.
Future<void> _flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

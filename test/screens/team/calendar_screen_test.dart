import 'package:holdclose/models/care_event.dart';
import 'package:holdclose/models/caregiver.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart'
    show assignableCaregiversProvider;
import 'package:holdclose/providers/patient_timeline_provider.dart';
import 'package:holdclose/screens/appointment/appointment_list_screen.dart'
    show appointmentAddDebounce;
import 'package:holdclose/screens/team/calendar_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

// A fixed "now" so the initially-shown week is deterministic. The week
// containing 2026-06-03 runs Sun May 31 → Sat Jun 6.
final DateTime _now = DateTime(2026, 6, 3, 8);

CareEvent _appointmentEvent() => CareEvent(
      id: 'appt-a1',
      kind: CareEventKind.appointment,
      title: 'Dr. Patel',
      start: DateTime(2026, 6, 3, 10),
      end: DateTime(2026, 6, 3, 11),
      patientId: _patientId,
      externalRef: 'a1',
    );

CareEvent _noteEvent() => CareEvent(
      id: 'note-n1',
      kind: CareEventKind.note,
      title: 'Pick up prescription',
      start: DateTime(2026, 6, 3, 13),
      patientId: _patientId,
    );

/// A dose occurrence carrying its window label + anchor slot — what the
/// patient-timeline stream feeds the calendar. [taken] picks the logged vs
/// scheduled kind. `start` is pinned to the slot so the day filter keeps
/// it on the window's day.
CareEvent _dose({
  required String id,
  required String med,
  required DateTime slot,
  required String window,
  required bool taken,
}) =>
    CareEvent(
      id: id,
      kind: taken ? CareEventKind.doseLogged : CareEventKind.doseScheduled,
      title: med,
      start: slot,
      patientId: _patientId,
      windowLabel: window,
      windowSlot: slot,
    );

GoRouter _router() {
  return GoRouter(
    initialLocation: '/team/calendar',
    routes: <RouteBase>[
      GoRoute(
        path: '/team',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST /team'))),
      ),
      GoRoute(
        path: '/team/calendar',
        builder: (BuildContext c, GoRouterState s) => const CalendarScreen(),
      ),
      GoRoute(
        path: '/appointments/new',
        builder: (BuildContext c, GoRouterState s) => Scaffold(
          body: Center(
            child: Text('ADD FORM ${s.uri.queryParameters['date'] ?? ''}'),
          ),
        ),
      ),
      GoRoute(
        path: '/appointments/:id',
        builder: (BuildContext c, GoRouterState s) =>
            Scaffold(body: Center(child: Text('APPT ${s.pathParameters['id']}'))),
      ),
      GoRoute(
        path: '/medications/today',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('TODAY MEDS'))),
      ),
    ],
  );
}

/// Pump the screen with [teamEvents] feeding [careEventsProvider]. The
/// patient timeline stream is stubbed empty so the merged async value
/// resolves immediately; the merged stream is the team feed only.
Future<GoRouter> _pump(
  WidgetTester tester, {
  required List<CareEvent> events,
  List<CareEvent> timeline = const <CareEvent>[],
  List<Caregiver> caregivers = const <Caregiver>[],
}) async {
  await tester.binding.setSurfaceSize(const Size(460, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = _router();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        careEventsProvider.overrideWith((Ref ref) async => events),
        patientTimelineEventsProvider
            .overrideWith((Ref ref) async => timeline),
        calendarClockProvider.overrideWithValue(() => _now),
        assignableCaregiversProvider
            .overrideWith((Ref ref) async => caregivers),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.last.matchedLocation;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The "Add appointment" affordances share a process-wide debounce that
  // drops a rapid second tap (the duplicate-appointment guard). Reset it
  // before each case so one test's FAB tap doesn't suppress the next.
  setUp(appointmentAddDebounce.reset);

  group('CalendarScreen — who-does-what filter (#4)', () {
    Caregiver cg(String id, String name) =>
        Caregiver(id: id, displayName: name, role: CaregiverRole.other);

    CareEvent ownedNote(String id, String title, String owner) => CareEvent(
          id: id,
          kind: CareEventKind.note,
          title: title,
          start: DateTime(2026, 6, 3, 12),
          patientId: _patientId,
          ownerCaregiverId: owner,
        );

    testWidgets('Everyone shows all; a person → theirs + unassigned care',
        (WidgetTester tester) async {
      await _pump(
        tester,
        events: <CareEvent>[
          ownedNote('n-sam', 'Sam item', 'cg-sam'),
          ownedNote('n-bob', 'Bob item', 'cg-bob'),
          _appointmentEvent(), // unassigned loved-one care (owner null)
        ],
        caregivers: <Caregiver>[cg('cg-sam', 'Sam'), cg('cg-bob', 'Bob')],
      );

      // Default (Everyone) shows everything.
      expect(find.text('Sam item'), findsOneWidget);
      expect(find.text('Bob item'), findsOneWidget);
      expect(find.text('Dr. Patel'), findsOneWidget);

      // Narrow to Sam → Sam's item + the unassigned appointment; not Bob's.
      await tester.tap(find.byKey(const Key('calendar-owner-cg-sam')));
      await tester.pumpAndSettle();
      expect(find.text('Sam item'), findsOneWidget);
      expect(find.text('Dr. Patel'), findsOneWidget); // unassigned care stays
      expect(find.text('Bob item'), findsNothing); // someone else's drops

      // Back to Everyone → Bob's item returns.
      await tester.tap(find.byKey(const Key('calendar-owner-everyone')));
      await tester.pumpAndSettle();
      expect(find.text('Bob item'), findsOneWidget);
    });

    testWidgets('with no care circle, the filter is hidden but events show',
        (WidgetTester tester) async {
      await _pump(
        tester,
        events: <CareEvent>[_appointmentEvent()],
        caregivers: const <Caregiver>[],
      );
      expect(find.byKey(const Key('calendar-owner-everyone')), findsNothing);
      expect(find.text('Dr. Patel'), findsOneWidget);
    });
  });

  group('CalendarScreen', () {
    testWidgets('renders the path header, week label, and agenda',
        (WidgetTester tester) async {
      await _pump(tester, events: <CareEvent>[_appointmentEvent()]);

      // The calendar is now titled "Schedule" (one schedule under Care).
      expect(find.text('Schedule'), findsWidgets);
      expect(find.byKey(CalendarScreen.gridKey), findsOneWidget);
      expect(find.byKey(CalendarScreen.weekLabelKey), findsOneWidget);
      // The week containing Jun 3 is May 31 – Jun 6.
      expect(find.text('May 31 – Jun 6'), findsOneWidget);
    });

    testWidgets('renders a row per event on the selected day',
        (WidgetTester tester) async {
      await _pump(tester,
          events: <CareEvent>[_appointmentEvent(), _noteEvent()]);

      // The default selected day is "today" (Jun 3) — both events are on
      // that day, so both rows render.
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('note-n1')), findsOneWidget);
      expect(find.text('Dr. Patel'), findsOneWidget);
    });

    testWidgets('tapping an appointment row routes to the source detail',
        (WidgetTester tester) async {
      final GoRouter router =
          await _pump(tester, events: <CareEvent>[_appointmentEvent()]);

      await tester.tap(find.byKey(CalendarScreen.blockKey('appt-a1')));
      await tester.pumpAndSettle();

      expect(_path(router), '/appointments/a1');
      expect(find.text('APPT a1'), findsOneWidget);
    });

    testWidgets('tapping a note row (no detail page) stays on the calendar',
        (WidgetTester tester) async {
      final GoRouter router =
          await _pump(tester, events: <CareEvent>[_noteEvent()]);

      await tester.tap(find.byKey(CalendarScreen.blockKey('note-n1')));
      await tester.pumpAndSettle();

      expect(_path(router), '/team/calendar');
    });

    testWidgets('week arrows cycle the visible week and drop out-of-week events',
        (WidgetTester tester) async {
      final GoRouter router =
          await _pump(tester, events: <CareEvent>[_appointmentEvent()]);

      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);

      await tester.tap(find.byKey(CalendarScreen.nextWeekKey));
      await tester.pumpAndSettle();

      // The event is in the prior week now — its row is gone and the
      // label advanced a week (Jun 7 – 13). The empty-day placeholder
      // takes the agenda slot.
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsNothing);
      expect(find.byKey(CalendarScreen.emptyDayKey), findsOneWidget);
      expect(find.text('Jun 7 – 13'), findsOneWidget);
      expect(_path(router), '/team/calendar');

      await tester.tap(find.byKey(CalendarScreen.prevWeekKey));
      await tester.pumpAndSettle();
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);
      expect(find.text('May 31 – Jun 6'), findsOneWidget);
    });

    testWidgets('in Day view, tapping a day chip narrows the agenda to that day',
        (WidgetTester tester) async {
      // Two events: Wed Jun 3 (today) appointment + Thu Jun 4 note. In Day
      // view the default selection is today, so only the appointment shows;
      // tapping the Thursday chip should swap the row.
      final CareEvent thuNote = CareEvent(
        id: 'note-thu',
        kind: CareEventKind.note,
        title: 'Pharmacy refill',
        start: DateTime(2026, 6, 4, 9),
        patientId: _patientId,
      );
      await _pump(
        tester,
        events: <CareEvent>[_appointmentEvent(), thuNote],
      );

      // Switch to Day so the agenda is single-day (Week would show both).
      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();

      // Day view → Wed selected.
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('note-thu')), findsNothing);

      // Tap the Thursday chip.
      await tester.tap(
        find.byKey(CalendarScreen.dayChipKey(DateTime(2026, 6, 4))),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsNothing);
      expect(find.byKey(CalendarScreen.blockKey('note-thu')), findsOneWidget);
    });
  });

  group('CalendarScreen — medication windows (parity with Home)', () {
    testWidgets("folds the day's doses into one window card, not a row per dose",
        (WidgetTester tester) async {
      final DateTime slot = DateTime(2026, 6, 3, 8); // 8am Morning window
      await _pump(
        tester,
        events: const <CareEvent>[],
        timeline: <CareEvent>[
          _dose(
              id: 'd1',
              med: 'Donepezil',
              slot: slot,
              window: 'Morning',
              taken: true),
          _dose(
              id: 'd2',
              med: 'Metformin',
              slot: slot,
              window: 'Morning',
              taken: false),
        ],
      );

      // One window header + anchor time (the calendar's compact clock),
      // both meds listed beneath it.
      expect(find.textContaining('Morning Medication'), findsOneWidget);
      expect(find.text('8 AM'), findsOneWidget);
      expect(find.text('Donepezil'), findsOneWidget);
      expect(find.text('Metformin'), findsOneWidget);

      // Exactly one grouped block (keyed by the first dose), not one per
      // dose, and no raw per-dose kind labels leak through.
      expect(find.byKey(CalendarScreen.blockKey('d1')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('d2')), findsNothing);
      expect(find.text('Dose'), findsNothing);
      expect(find.text('Dose taken'), findsNothing);
    });

    testWidgets("tapping today's window card opens the dose log",
        (WidgetTester tester) async {
      final DateTime slot = DateTime(2026, 6, 3, 8);
      final GoRouter router = await _pump(
        tester,
        events: const <CareEvent>[],
        timeline: <CareEvent>[
          _dose(
              id: 'd1',
              med: 'Donepezil',
              slot: slot,
              window: 'Morning',
              taken: false),
        ],
      );

      await tester.tap(find.byKey(CalendarScreen.blockKey('d1')));
      await tester.pumpAndSettle();

      expect(_path(router), '/medications/today');
      expect(find.text('TODAY MEDS'), findsOneWidget);
    });

    testWidgets('a non-today window card has no tap destination',
        (WidgetTester tester) async {
      final DateTime thuSlot = DateTime(2026, 6, 4, 8); // Thursday
      final GoRouter router = await _pump(
        tester,
        events: const <CareEvent>[],
        timeline: <CareEvent>[
          _dose(
              id: 'thu1',
              med: 'Donepezil',
              slot: thuSlot,
              window: 'Morning',
              taken: false),
        ],
      );

      // Switch to Day (which carries the day strip) and select Thursday so
      // the dose's day is shown.
      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(CalendarScreen.dayChipKey(DateTime(2026, 6, 4))));
      await tester.pumpAndSettle();
      expect(find.textContaining('Morning Medication'), findsOneWidget);

      // Tapping a future window stays on the calendar (the dose log is
      // today-scoped).
      await tester.tap(find.byKey(CalendarScreen.blockKey('thu1')));
      await tester.pumpAndSettle();
      expect(_path(router), '/team/calendar');
    });
  });

  group('CalendarScreen — add affordance (#2)', () {
    testWidgets('the FAB is present and opens the appointment form',
        (WidgetTester tester) async {
      final GoRouter router =
          await _pump(tester, events: <CareEvent>[_appointmentEvent()]);

      expect(find.byKey(CalendarScreen.addFabKey), findsOneWidget);

      await tester.tap(find.byKey(CalendarScreen.addFabKey));
      await tester.pumpAndSettle();

      // Routed to the appointment-new form, anchored on the selected day
      // (today = Jun 3) via the ?date= param.
      expect(_path(router), '/appointments/new');
      expect(find.text('ADD FORM 2026-06-03'), findsOneWidget);
    });

    testWidgets('the FAB passes the day the caregiver selected',
        (WidgetTester tester) async {
      final GoRouter router =
          await _pump(tester, events: <CareEvent>[_appointmentEvent()]);

      // Switch to Day (the strip lives there), select Thursday Jun 4, then
      // tap Add — the form should anchor there.
      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(CalendarScreen.dayChipKey(DateTime(2026, 6, 4))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(CalendarScreen.addFabKey));
      await tester.pumpAndSettle();

      expect(_path(router), '/appointments/new');
      expect(find.text('ADD FORM 2026-06-04'), findsOneWidget);
    });
  });

  group('CalendarScreen — view switcher (#3)', () {
    // Two events on different days: today's (Jun 3) appointment + a
    // Thursday (Jun 4) note. The view toggle changes which render.
    CareEvent thuNote() => CareEvent(
          id: 'note-thu',
          kind: CareEventKind.note,
          title: 'Pharmacy refill',
          start: DateTime(2026, 6, 4, 9),
          patientId: _patientId,
        );

    testWidgets('the switcher is present and defaults to Week',
        (WidgetTester tester) async {
      await _pump(tester, events: <CareEvent>[_appointmentEvent()]);
      expect(find.byKey(CalendarScreen.viewSwitcherKey), findsOneWidget);
      // Week view keeps the week-cycling header + agenda.
      expect(find.byKey(CalendarScreen.weekLabelKey), findsOneWidget);
      expect(find.byKey(CalendarScreen.gridKey), findsOneWidget);
    });

    testWidgets(
        'Week view hides the day-of-week strip; Day view shows it '
        '(fb_1780960170044232)', (WidgetTester tester) async {
      await _pump(tester, events: <CareEvent>[_appointmentEvent()]);

      // Default is Week → the day chip strip is gone (it was inert there:
      // every day already renders, so tapping a chip did nothing).
      expect(
        find.byKey(CalendarScreen.dayChipKey(DateTime(2026, 6, 3))),
        findsNothing,
      );

      // Switch to Day → the strip returns so the caregiver can hop days.
      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(CalendarScreen.dayChipKey(DateTime(2026, 6, 3))),
        findsOneWidget,
      );
    });

    testWidgets('Day view shows only the selected day; the week strip stays',
        (WidgetTester tester) async {
      await _pump(
        tester,
        events: <CareEvent>[_appointmentEvent(), thuNote()],
      );

      // Switch to Day.
      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();

      // Selected day is today (Jun 3): its appointment renders, Thursday's
      // note does not. The week strip is still there so the caregiver can
      // hop days.
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('note-thu')), findsNothing);
      expect(find.byKey(CalendarScreen.weekLabelKey), findsOneWidget);
    });

    testWidgets(
        'Week and Day show different ranges: an event later in the week is in '
        'Week but not Day',
        (WidgetTester tester) async {
      // Today is Wed Jun 3 (week Sun May 31 – Sat Jun 6). The note is on
      // Sat Jun 6 — same week, 3 days out. Week must show it; Day (anchored
      // on the selected day, today) must not. This is the regression guard
      // for "Day and Week show the exact same thing".
      final CareEvent satNote = CareEvent(
        id: 'note-sat',
        kind: CareEventKind.note,
        title: 'Weekend visit',
        start: DateTime(2026, 6, 6, 14),
        patientId: _patientId,
      );
      await _pump(
        tester,
        events: <CareEvent>[_appointmentEvent(), satNote],
      );

      // Default view is Week → both today's appointment AND Saturday's note
      // render, under their own date headers.
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('note-sat')), findsOneWidget);
      expect(find.byKey(const Key('calendar-week-agenda')), findsOneWidget);

      // Switch to Day → only today's appointment; Saturday's note drops out.
      // (The visible event set is genuinely narrower than Week's.)
      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('note-sat')), findsNothing);
      expect(find.byKey(const Key('calendar-week-agenda')), findsNothing);
    });

    testWidgets('Week empty state reflects the week, not a single day',
        (WidgetTester tester) async {
      // Today Jun 3; the only event is next week (Jun 10), out of the
      // visible week → the Week agenda is empty and says so for the week.
      final CareEvent nextWeek = CareEvent(
        id: 'note-next',
        kind: CareEventKind.note,
        title: 'Later',
        start: DateTime(2026, 6, 10, 9),
        patientId: _patientId,
      );
      await _pump(tester, events: <CareEvent>[nextWeek]);

      expect(find.byKey(CalendarScreen.emptyDayKey), findsOneWidget);
      expect(find.text('Nothing scheduled this week.'), findsOneWidget);
    });

    testWidgets(
        'Upcoming view drops the week strip and lists the horizon',
        (WidgetTester tester) async {
      await _pump(
        tester,
        events: <CareEvent>[_appointmentEvent(), thuNote()],
      );

      // Switch to Upcoming.
      await tester.tap(find.text('Upcoming'));
      await tester.pumpAndSettle();

      // The flat horizon list replaces the week strip + day agenda. BOTH
      // days' events render (today's appointment + Thursday's note), under
      // their date headers — the week/day views never showed both at once.
      expect(find.byKey(CalendarScreen.upcomingListKey), findsOneWidget);
      expect(find.byKey(CalendarScreen.weekLabelKey), findsNothing);
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('note-thu')), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Pharmacy refill'), findsOneWidget);
    });

    testWidgets(
        'Upcoming horizon reaches well past the visible week '
        '(fb_1780960227608706)', (WidgetTester tester) async {
      // Today is Jun 3; the visible week ends Sat Jun 6. An event 20 days
      // out (Jun 23) must still appear in Upcoming — the prior 14-day
      // horizon barely cleared the week ("only goes one day past week").
      final CareEvent farOut = CareEvent(
        id: 'note-far',
        kind: CareEventKind.note,
        title: 'Three weeks out',
        start: DateTime(2026, 6, 23, 10),
        patientId: _patientId,
      );
      // An event past the 30-day horizon (Jul 20, ~47 days out) must NOT
      // appear — the horizon is finite.
      final CareEvent tooFar = CareEvent(
        id: 'note-toofar',
        kind: CareEventKind.note,
        title: 'Way out',
        start: DateTime(2026, 7, 20, 10),
        patientId: _patientId,
      );
      await _pump(tester, events: <CareEvent>[farOut, tooFar]);

      await tester.tap(find.text('Upcoming'));
      await tester.pumpAndSettle();

      expect(find.byKey(CalendarScreen.blockKey('note-far')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('note-toofar')), findsNothing);
    });

    testWidgets('the owner filter still narrows the Upcoming view',
        (WidgetTester tester) async {
      CareEvent ownedNote(String id, String title, String owner, int day) =>
          CareEvent(
            id: id,
            kind: CareEventKind.note,
            title: title,
            start: DateTime(2026, 6, day, 12),
            patientId: _patientId,
            ownerCaregiverId: owner,
          );
      await _pump(
        tester,
        events: <CareEvent>[
          ownedNote('n-sam', 'Sam item', 'cg-sam', 3),
          ownedNote('n-bob', 'Bob item', 'cg-bob', 4),
        ],
        caregivers: <Caregiver>[
          const Caregiver(
              id: 'cg-sam', displayName: 'Sam', role: CaregiverRole.other),
          const Caregiver(
              id: 'cg-bob', displayName: 'Bob', role: CaregiverRole.other),
        ],
      );

      await tester.tap(find.text('Upcoming'));
      await tester.pumpAndSettle();
      // Both visible under Everyone.
      expect(find.text('Sam item'), findsOneWidget);
      expect(find.text('Bob item'), findsOneWidget);

      // Narrow to Sam → only Sam's item survives in the Upcoming list.
      await tester.tap(find.byKey(const Key('calendar-owner-cg-sam')));
      await tester.pumpAndSettle();
      expect(find.text('Sam item'), findsOneWidget);
      expect(find.text('Bob item'), findsNothing);
    });
  });

  group('CalendarScreen — windowed projection (fb_1780960326057462)', () {
    // A permanent med projects doses across the whole forecast horizon
    // (the timeline source now spans ~30 days). The calendar must clip each
    // view to its visible window so those doses don't render "forever" and
    // Day vs Week don't "end at different times". We feed a today dose +
    // a far-future dose (well outside the current day and week) and assert
    // the far one is absent in both Day and Week.
    CareEvent permanentDose(DateTime slot, String id) => _dose(
          id: id,
          med: 'Donepezil',
          slot: slot,
          window: 'Morning',
          taken: false,
        );

    testWidgets('Day view shows only the selected day, not future doses',
        (WidgetTester tester) async {
      await _pump(
        tester,
        events: const <CareEvent>[],
        timeline: <CareEvent>[
          permanentDose(DateTime(2026, 6, 3, 8), 'd-today'), // today
          permanentDose(DateTime(2026, 6, 20, 8), 'd-far'), // 17 days out
        ],
      );

      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();

      // Selected day is today (Jun 3): today's window renders, the far one
      // (still within the source's horizon) is clipped out.
      expect(find.byKey(CalendarScreen.blockKey('d-today')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('d-far')), findsNothing);
    });

    testWidgets('Week view shows only the selected week, not future doses',
        (WidgetTester tester) async {
      await _pump(
        tester,
        events: const <CareEvent>[],
        timeline: <CareEvent>[
          permanentDose(DateTime(2026, 6, 3, 8), 'd-today'), // this week
          permanentDose(DateTime(2026, 6, 20, 8), 'd-far'), // 2+ weeks out
        ],
      );

      // Default is Week (May 31 – Jun 6): this week's dose renders, the
      // far-future dose is clipped — it does NOT extend past the window.
      expect(find.byKey(CalendarScreen.blockKey('d-today')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('d-far')), findsNothing);
    });

    testWidgets('Day and Week clip to the same far boundary for a paged week',
        (WidgetTester tester) async {
      // A dose on Sat Jun 6 (last day of the current week) and one on Sun
      // Jun 7 (first day of the NEXT week). In the current week, Week shows
      // Jun 6 but not Jun 7 — i.e. the week boundary, not an arbitrary
      // "today + 7" horizon, decides the edge (the "ending at different
      // times" complaint).
      await _pump(
        tester,
        events: const <CareEvent>[],
        timeline: <CareEvent>[
          permanentDose(DateTime(2026, 6, 6, 8), 'd-sat'), // in week
          permanentDose(DateTime(2026, 6, 7, 8), 'd-sun'), // next week
        ],
      );

      // Week view: Saturday in, Sunday (next week) out.
      expect(find.byKey(CalendarScreen.blockKey('d-sat')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('d-sun')), findsNothing);
    });
  });

  group('CalendarScreen — initialDate (chat "take me to that day")', () {
    testWidgets('opens on the passed day\'s week, not today\'s',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(460, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Today is Jun 3 (week May 31 – Jun 6). Open on Jun 18 instead.
      final GoRouter router = GoRouter(
        initialLocation: '/cal',
        routes: <RouteBase>[
          GoRoute(
            path: '/cal',
            builder: (BuildContext c, GoRouterState s) =>
                CalendarScreen(initialDate: DateTime(2026, 6, 18)),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            careEventsProvider
                .overrideWith((Ref ref) async => const <CareEvent>[]),
            patientTimelineEventsProvider
                .overrideWith((Ref ref) async => const <CareEvent>[]),
            calendarClockProvider.overrideWithValue(() => _now),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Jun 18 2026 falls in the week Sun Jun 14 – Sat Jun 20. The default
      // Week view shows the week label; the day strip only appears in Day
      // view, so switch there to confirm Jun 18 is the selected chip.
      expect(find.text('Jun 14 – 20'), findsOneWidget);
      expect(find.text('May 31 – Jun 6'), findsNothing);
      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();
      expect(find.byKey(CalendarScreen.dayChipKey(DateTime(2026, 6, 18))),
          findsOneWidget);
    });
  });
}

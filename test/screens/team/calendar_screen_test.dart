import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/providers/care_events_provider.dart';
import 'package:careblazers/providers/patient_timeline_provider.dart';
import 'package:careblazers/screens/team/calendar_screen.dart';
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
        path: '/appointments/:id',
        builder: (BuildContext c, GoRouterState s) =>
            Scaffold(body: Center(child: Text('APPT ${s.pathParameters['id']}'))),
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
}) async {
  await tester.binding.setSurfaceSize(const Size(460, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = _router();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        careEventsProvider.overrideWith((Ref ref) async => events),
        patientTimelineEventsProvider
            .overrideWith((Ref ref) async => const <CareEvent>[]),
        calendarClockProvider.overrideWithValue(() => _now),
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

  group('CalendarScreen', () {
    testWidgets('renders the path header, week label, and agenda',
        (WidgetTester tester) async {
      await _pump(tester, events: <CareEvent>[_appointmentEvent()]);

      expect(find.text('Calendar'), findsWidgets);
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

    testWidgets('tapping a day chip narrows the agenda to that day',
        (WidgetTester tester) async {
      // Two events: Wed Jun 3 (today) appointment + Thu Jun 4 note. The
      // default selection is today, so only the appointment shows;
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

      // Default → Wed selected.
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
}

import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/providers/care_events_provider.dart';
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
    testWidgets('renders the path header, week label, and grid',
        (WidgetTester tester) async {
      await _pump(tester, events: <CareEvent>[_appointmentEvent()]);

      expect(find.text('Calendar'), findsWidgets);
      expect(find.byKey(CalendarScreen.gridKey), findsOneWidget);
      expect(find.byKey(CalendarScreen.weekLabelKey), findsOneWidget);
      // The week containing Jun 3 is May 31 – Jun 6.
      expect(find.text('May 31 – Jun 6'), findsOneWidget);
    });

    testWidgets('renders a block per in-week event',
        (WidgetTester tester) async {
      await _pump(tester,
          events: <CareEvent>[_appointmentEvent(), _noteEvent()]);

      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);
      expect(find.byKey(CalendarScreen.blockKey('note-n1')), findsOneWidget);
      expect(find.text('Dr. Patel'), findsOneWidget);
    });

    testWidgets('tapping an appointment block routes to the source detail',
        (WidgetTester tester) async {
      final GoRouter router =
          await _pump(tester, events: <CareEvent>[_appointmentEvent()]);

      await tester.tap(find.byKey(CalendarScreen.blockKey('appt-a1')));
      await tester.pumpAndSettle();

      expect(_path(router), '/appointments/a1');
      expect(find.text('APPT a1'), findsOneWidget);
    });

    testWidgets('tapping a note block (no detail page) stays on the calendar',
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

      // The event is in the prior week now — its block is gone and the
      // label advanced a week (Jun 7 – 13).
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsNothing);
      expect(find.text('Jun 7 – 13'), findsOneWidget);
      expect(_path(router), '/team/calendar');

      await tester.tap(find.byKey(CalendarScreen.prevWeekKey));
      await tester.pumpAndSettle();
      expect(find.byKey(CalendarScreen.blockKey('appt-a1')), findsOneWidget);
      expect(find.text('May 31 – Jun 6'), findsOneWidget);
    });
  });
}

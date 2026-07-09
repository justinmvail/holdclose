import 'package:holdclose/models/appointment.dart' show AppointmentStatus;
import 'package:holdclose/models/care_event.dart';
import 'package:holdclose/providers/home_clock_provider.dart';
import 'package:holdclose/providers/patient_timeline_provider.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/home/schedule_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patient = 'demo-patient-mary';

CareEvent _e({
  required String id,
  required DateTime start,
  CareEventKind kind = CareEventKind.appointment,
  String title = 'event',
}) =>
    CareEvent(
      id: id,
      kind: kind,
      title: title,
      start: start,
      patientId: _patient,
    );

void main() {
  // Pinned wall clock used across the suite: Mon Jun 1, 2026 11:00.
  final DateTime now = DateTime(2026, 6, 1, 11, 0);

  group('ScheduleCard.bucketSchedule', () {
    test('separates today and tomorrow, dropping later days', () {
      final List<CareEvent> events = <CareEvent>[
        // Already happened earlier today — still belongs in "Today".
        _e(id: 'past', start: DateTime(2026, 6, 1, 8)),
        // Later today.
        _e(id: 'today', start: DateTime(2026, 6, 1, 14)),
        // Tomorrow.
        _e(id: 'tmrw', start: DateTime(2026, 6, 2, 9)),
        // Day after tomorrow — dropped (card looks one day ahead).
        _e(id: 'later', start: DateTime(2026, 6, 3, 9)),
        // Later in the week (Friday) — dropped.
        _e(id: 'week', start: DateTime(2026, 6, 5, 9)),
      ];
      final ({List<CareEvent> today, List<CareEvent> tomorrow}) buckets =
          bucketSchedule(events, now);

      expect(
        buckets.today.map((CareEvent e) => e.id),
        <String>['past', 'today'],
      );
      expect(buckets.tomorrow.map((CareEvent e) => e.id), <String>['tmrw']);
    });

    test('drops events before today and from the day after tomorrow on', () {
      final List<CareEvent> events = <CareEvent>[
        // Yesterday — dropped.
        _e(id: 'yesterday', start: DateTime(2026, 5, 31, 9)),
        // Day after tomorrow — dropped.
        _e(id: 'day-after', start: DateTime(2026, 6, 3, 9)),
        // In-window control.
        _e(id: 'today', start: DateTime(2026, 6, 1, 14)),
      ];
      final ({List<CareEvent> today, List<CareEvent> tomorrow}) buckets =
          bucketSchedule(events, now);

      expect(buckets.today.map((CareEvent e) => e.id), <String>['today']);
      expect(buckets.tomorrow, isEmpty);
    });

    test('returns two empty buckets when the input is empty', () {
      final ({List<CareEvent> today, List<CareEvent> tomorrow}) buckets =
          bucketSchedule(const <CareEvent>[], now);
      expect(buckets.today, isEmpty);
      expect(buckets.tomorrow, isEmpty);
    });
  });

  group('ScheduleCard — first-run empty state', () {
    Future<void> pumpEmpty(WidgetTester tester, {List<String>? nav}) async {
      final GoRouter router = GoRouter(
        initialLocation: '/',
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: ScheduleCard(),
              ),
            ),
            routes: <RouteBase>[
              for (final String p in <String>['medications/new', 'scan', 'chat'])
                GoRoute(
                  path: p,
                  builder: (_, GoRouterState s) {
                    nav?.add('/${s.uri.path.replaceFirst('/', '')}');
                    return const Scaffold(body: Text('dest'));
                  },
                ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            homeClockProvider.overrideWithValue(() => now),
            patientTimelineEventsProvider
                .overrideWith((Ref ref) async => const <CareEvent>[]),
            scheduleAppointmentStatusProvider.overrideWith(
              (Ref ref) async => const <String, AppointmentStatus>{},
            ),
          ],
          child: MaterialApp.router(
            theme: ThemeData(
              extensions: const <ThemeExtension<dynamic>>[holdcloseColors],
            ),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows instructive copy + three quick-start CTAs',
        (WidgetTester tester) async {
      await pumpEmpty(tester);

      expect(find.byKey(ScheduleCard.emptyKey), findsOneWidget);
      expect(find.text('Nothing scheduled yet.'), findsOneWidget);
      expect(find.byKey(ScheduleCard.emptyAddMedKey), findsOneWidget);
      expect(find.byKey(ScheduleCard.emptyScanKey), findsOneWidget);
      expect(find.byKey(ScheduleCard.emptyAskCoachKey), findsOneWidget);
    });

    testWidgets('the Add-a-medication CTA routes to /medications/new',
        (WidgetTester tester) async {
      final List<String> nav = <String>[];
      await pumpEmpty(tester, nav: nav);

      await tester.tap(find.byKey(ScheduleCard.emptyAddMedKey));
      await tester.pumpAndSettle();
      expect(nav, contains('/medications/new'));
    });
  });
}

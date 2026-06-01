import 'dart:async';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/medications_today_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Fixed "now": 11 AM on Sat May 30 2026 — past the 8 AM morning dose,
/// inside the 2-hour window before the 12:30 PM dose, and well before the
/// 8 PM evening dose, so taken / due-soon / overdue / upcoming all appear
/// in one render.
DateTime _fixedNow() => DateTime(2026, 5, 30, 11, 0);

Medication _med(String id, String name, String dosage) => Medication(
      id: id,
      name: name,
      dosage: dosage,
      route: MedicationRoute.oral,
    );

DoseSchedule _dailyAt(String id, String medicationId, int hour, int minute) =>
    DoseSchedule(
      id: id,
      medicationId: medicationId,
      frequencyKind: FrequencyKind.daily,
      timesOfDay: <TimeOfDay>[TimeOfDay(hour: hour, minute: minute)],
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 5, 1),
    );

ScheduledDose _dose({
  required String medId,
  required DateTime at,
  DoseStatus? status,
}) {
  final Medication med = _med(medId, medId, '10 mg');
  return ScheduledDose(
    medication: med,
    schedule: _dailyAt('sched-$medId', medId, at.hour, at.minute),
    scheduledFor: at,
    log: status == null
        ? null
        : DoseLog(
            id: 'log-$medId',
            medicationId: medId,
            scheduledFor: at,
            takenAt:
                (status == DoseStatus.taken || status == DoseStatus.late)
                    ? at
                    : null,
            status: status,
          ),
  );
}

/// Pumps the card inside a two-route harness so the whole-card tap can
/// resolve `pushNamed(medicationDoseLog)` end to end.
Future<GoRouter> _pumpCard(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) => const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: MedicationsTodayCard(),
          ),
        ),
      ),
      GoRoute(
        path: '/medications/today',
        name: CareblazersRoutes.medicationDoseLog,
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Text('DOSE LOG DEST')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        routerConfig: router,
        theme: careblazersLightTheme,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

List<Override> _repoOverrides(MedicationRepository repo) => <Override>[
      medicationRepositoryBackendProvider.overrideWithValue(repo),
      doseLogClockProvider.overrideWithValue(_fixedNow),
    ];

void main() {
  group('medicationsTodayCount — X-of-Y math (Phase 14.9)', () {
    test('a mix of taken / due / overdue counts taken over total', () {
      final List<ScheduledDose> doses = <ScheduledDose>[
        _dose(medId: 'a', at: DateTime(2026, 5, 30, 8), status: DoseStatus.taken),
        _dose(medId: 'b', at: DateTime(2026, 5, 30, 9), status: DoseStatus.late),
        // overdue (past, unlogged)
        _dose(medId: 'c', at: DateTime(2026, 5, 30, 10)),
        // due soon (within 2h, unlogged)
        _dose(medId: 'd', at: DateTime(2026, 5, 30, 12, 30)),
        // upcoming (more than 2h out, unlogged)
        _dose(medId: 'e', at: DateTime(2026, 5, 30, 20)),
      ];

      final ({int taken, int total}) count = medicationsTodayCount(doses);
      // taken + late both count as given; the other three are pending.
      expect(count.taken, 2);
      expect(count.total, 5);
    });

    test('skipped and missed logs do not count as taken', () {
      final List<ScheduledDose> doses = <ScheduledDose>[
        _dose(medId: 'a', at: DateTime(2026, 5, 30, 8), status: DoseStatus.skipped),
        _dose(medId: 'b', at: DateTime(2026, 5, 30, 9), status: DoseStatus.missed),
        _dose(medId: 'c', at: DateTime(2026, 5, 30, 10), status: DoseStatus.taken),
      ];

      final ({int taken, int total}) count = medicationsTodayCount(doses);
      expect(count.taken, 1);
      expect(count.total, 3);
    });

    test('empty list is 0 of 0', () {
      expect(
        medicationsTodayCount(const <ScheduledDose>[]),
        (taken: 0, total: 0),
      );
    });
  });

  group('dose status resolution — taken / due / overdue', () {
    final DateTime now = _fixedNow();

    test('a taken (or late) log is teal "Taken"', () {
      final ScheduledDose taken =
          _dose(medId: 'a', at: DateTime(2026, 5, 30, 8), status: DoseStatus.taken);
      expect(medicationDoseStatusLabel(taken, now), 'Taken');
      expect(medicationDoseStatusColor(taken, now),
          MedicationsTodayCard.takenColor);

      final ScheduledDose late =
          _dose(medId: 'b', at: DateTime(2026, 5, 30, 9), status: DoseStatus.late);
      expect(medicationDoseStatusLabel(late, now), 'Taken');
      expect(medicationDoseStatusColor(late, now),
          MedicationsTodayCard.takenColor);
    });

    test('an unlogged dose within 2h is amber "Due soon"', () {
      final ScheduledDose due =
          _dose(medId: 'd', at: DateTime(2026, 5, 30, 12, 30));
      expect(medicationDoseStatusLabel(due, now), 'Due soon');
      expect(medicationDoseStatusColor(due, now),
          MedicationsTodayCard.dueSoonColor);
    });

    test('an unlogged dose past its time is coral "Overdue"', () {
      final ScheduledDose overdue =
          _dose(medId: 'c', at: DateTime(2026, 5, 30, 10));
      expect(medicationDoseStatusLabel(overdue, now), 'Overdue');
      expect(medicationDoseStatusColor(overdue, now),
          MedicationsTodayCard.overdueColor);
    });

    test('an unlogged dose more than 2h out is muted "Upcoming"', () {
      final ScheduledDose upcoming =
          _dose(medId: 'e', at: DateTime(2026, 5, 30, 20));
      expect(medicationDoseStatusLabel(upcoming, now), 'Upcoming');
      expect(medicationDoseStatusColor(upcoming, now),
          careblazersColors.primarySoft);
    });
  });

  group('MedicationsTodayCard — empty state', () {
    late CareblazersDatabase db;
    late MedicationRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = MedicationRepository(db, clock: _fixedNow);
    });
    tearDown(() => db.close());

    testWidgets('renders "No medications today." with no scheduled doses',
        (WidgetTester tester) async {
      await _pumpCard(tester, overrides: _repoOverrides(repo));

      expect(find.byKey(MedicationsTodayCard.emptyKey), findsOneWidget);
      expect(find.text('No medications today.'), findsOneWidget);
      // No count chip and no dose list in the empty state.
      expect(find.byKey(MedicationsTodayCard.countKey), findsNothing);
      expect(find.byKey(MedicationsTodayCard.listKey), findsNothing);
      // Header is always present.
      expect(find.text('Medications Today'), findsOneWidget);
    });
  });

  group('MedicationsTodayCard — populated', () {
    late CareblazersDatabase db;
    late MedicationRepository repo;

    setUp(() async {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = MedicationRepository(db, clock: _fixedNow);

      // 8 AM Donepezil — taken on time.
      await repo.upsertMedication(_med('med-don', 'Donepezil', '10 mg'));
      await repo.upsertSchedule(_dailyAt('sched-don', 'med-don', 8, 0));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-don',
        medicationId: 'med-don',
        scheduledFor: DateTime(2026, 5, 30, 8),
        takenAt: DateTime(2026, 5, 30, 8, 1),
        status: DoseStatus.taken,
      ));

      // 10 AM Sertraline — overdue (past, unlogged).
      await repo.upsertMedication(_med('med-sert', 'Sertraline', '50 mg'));
      await repo.upsertSchedule(_dailyAt('sched-sert', 'med-sert', 10, 0));

      // 12:30 PM Memantine — due soon (within 2h, unlogged).
      await repo.upsertMedication(_med('med-mem', 'Memantine', '10 mg'));
      await repo.upsertSchedule(_dailyAt('sched-mem', 'med-mem', 12, 30));
    });
    tearDown(() => db.close());

    testWidgets('header shows the X-of-Y count', (WidgetTester tester) async {
      await _pumpCard(tester, overrides: _repoOverrides(repo));

      expect(find.byKey(MedicationsTodayCard.listKey), findsOneWidget);
      // One of three doses taken.
      final Text count =
          tester.widget<Text>(find.byKey(MedicationsTodayCard.countKey));
      expect(count.data, '1 of 3');
    });

    testWidgets('renders a row per dose with name, strength and status',
        (WidgetTester tester) async {
      await _pumpCard(tester, overrides: _repoOverrides(repo));

      expect(find.text('Donepezil'), findsNothing); // name is in a TextSpan
      // Names render inside Text.rich; assert via the row keys + statuses.
      expect(
        find.byKey(MedicationsTodayCard.rowKey('med-don', DateTime(2026, 5, 30, 8))),
        findsOneWidget,
      );
      expect(
        find.byKey(MedicationsTodayCard.rowKey('med-sert', DateTime(2026, 5, 30, 10))),
        findsOneWidget,
      );
      expect(
        find.byKey(MedicationsTodayCard.rowKey(
            'med-mem', DateTime(2026, 5, 30, 12, 30))),
        findsOneWidget,
      );

      // Status strings: taken / overdue / due soon, one each.
      expect(find.text('Taken'), findsOneWidget);
      expect(find.text('Overdue'), findsOneWidget);
      expect(find.text('Due soon'), findsOneWidget);
    });
  });

  group('MedicationsTodayCard — loading skeleton', () {
    testWidgets('shows the skeleton while the provider is unresolved',
        (WidgetTester tester) async {
      final Completer<List<ScheduledDose>> pending =
          Completer<List<ScheduledDose>>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(const <ScheduledDose>[]);
      });

      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            dosesTodayProvider.overrideWith((ref) => pending.future),
            doseLogClockProvider.overrideWithValue(_fixedNow),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: MedicationsTodayCard(),
              ),
            ),
          ),
        ),
      );
      // A single pump (no settle) — the future is still pending.
      await tester.pump();

      expect(find.byKey(MedicationsTodayCard.skeletonKey), findsOneWidget);
      expect(find.byKey(MedicationsTodayCard.emptyKey), findsNothing);
      expect(find.byKey(MedicationsTodayCard.listKey), findsNothing);
    });
  });

  group('MedicationsTodayCard — navigation', () {
    late CareblazersDatabase db;
    late MedicationRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = MedicationRepository(db, clock: _fixedNow);
    });
    tearDown(() => db.close());

    testWidgets('tapping the card pushes /medications/today',
        (WidgetTester tester) async {
      await _pumpCard(tester, overrides: _repoOverrides(repo));

      expect(find.text('DOSE LOG DEST'), findsNothing);
      await tester.tap(find.byKey(MedicationsTodayCard.cardKey));
      await tester.pumpAndSettle();
      expect(find.text('DOSE LOG DEST'), findsOneWidget);
    });
  });
}

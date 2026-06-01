import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medical/med_schedule_screen.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart'
    show doseLogClockProvider;
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/widgets/home/medications_today_card.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Fixed "now": 11 AM on Saturday May 30 2026 — after an 8 AM dose but
/// before a 2 PM / 8 PM one, so "taken", "missed" and "due" all coexist.
DateTime _fixedNow() => DateTime(2026, 5, 30, 11, 0);

Medication _med({required String id, required String name}) => Medication(
      id: id,
      name: name,
      dosage: '10 mg',
      route: MedicationRoute.oral,
    );

DoseSchedule _dailyAt(
  String id,
  String medicationId, {
  required int hour,
  int minute = 0,
  DateTime? startsOn,
}) =>
    DoseSchedule(
      id: id,
      medicationId: medicationId,
      frequencyKind: FrequencyKind.daily,
      timesOfDay: <TimeOfDay>[TimeOfDay(hour: hour, minute: minute)],
      daysOfWeek: const <int>{},
      startsOn: startsOn ?? DateTime(2026, 5, 1),
    );

ScheduledDose _dose({
  required int hour,
  int minute = 0,
  DoseLog? log,
}) {
  const Medication med = Medication(
    id: 'm',
    name: 'Donepezil',
    dosage: '10 mg',
    route: MedicationRoute.oral,
  );
  final DateTime when = DateTime(2026, 5, 30, hour, minute);
  return ScheduledDose(
    medication: med,
    schedule: DoseSchedule(
      id: 's',
      medicationId: 'm',
      frequencyKind: FrequencyKind.daily,
      timesOfDay: <TimeOfDay>[TimeOfDay(hour: hour, minute: minute)],
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 5, 1),
    ),
    scheduledFor: when,
    log: log,
  );
}

Future<MedicationRepository> _pumpScreen(
  WidgetTester tester, {
  required MedicationRepository repo,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/medical/schedule',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/schedule',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const MedScheduleScreen(),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        doseLogClockProvider.overrideWithValue(_fixedNow),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  late CareblazersDatabase db;
  late MedicationRepository repo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = MedicationRepository(db, clock: _fixedNow);
  });

  tearDown(() async {
    await db.close();
  });

  group('MedScheduleScreen — header', () {
    testWidgets('renders the path header + back-to-Medical control',
        (WidgetTester tester) async {
      await _pumpScreen(tester, repo: repo);
      expect(find.text('Med Schedule'), findsWidgets);
      expect(find.text('Back to Medical'), findsOneWidget);
    });

    testWidgets('opens on Today', (WidgetTester tester) async {
      await _pumpScreen(tester, repo: repo);
      expect(
        tester.widget<Text>(find.byKey(MedScheduleScreen.dayLabelKey)).data,
        'Today',
      );
    });
  });

  group('MedScheduleScreen — marker positions (±1px of scheduled time)', () {
    testWidgets('marker vertical offsets track the scheduled hour-of-day',
        (WidgetTester tester) async {
      // Three doses at 8:00, 8:30 and 14:00 on the displayed day.
      await repo.upsertMedication(_med(id: 'a', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sa', 'a', hour: 8));
      await repo.upsertMedication(_med(id: 'b', name: 'Sertraline'));
      await repo.upsertSchedule(_dailyAt('sb', 'b', hour: 8, minute: 30));
      await repo.upsertMedication(_med(id: 'c', name: 'Memantine'));
      await repo.upsertSchedule(_dailyAt('sc', 'c', hour: 14));

      await _pumpScreen(tester, repo: repo);

      double top(String medId, DateTime when) =>
          tester.getTopLeft(find.byKey(MedScheduleScreen.markerKey(medId, when)))
              .dy;

      final double y8 = top('a', DateTime(2026, 5, 30, 8));
      final double y830 = top('b', DateTime(2026, 5, 30, 8, 30));
      final double y14 = top('c', DateTime(2026, 5, 30, 14));

      // 30 minutes = half an hour-cell; 6 hours = six cells. The deltas
      // must match the time spans to within a pixel.
      expect(
        y830 - y8,
        closeTo(0.5 * MedScheduleScreen.hourHeight, 1.0),
      );
      expect(
        y14 - y8,
        closeTo(6 * MedScheduleScreen.hourHeight, 1.0),
      );
    });

    test('offsetForTime maps minutes-since-midnight onto pixels', () {
      expect(
        MedScheduleScreen.offsetForTime(DateTime(2026, 5, 30, 0)),
        0.0,
      );
      expect(
        MedScheduleScreen.offsetForTime(DateTime(2026, 5, 30, 6)),
        6 * MedScheduleScreen.hourHeight,
      );
      expect(
        MedScheduleScreen.offsetForTime(DateTime(2026, 5, 30, 8, 30)),
        closeTo(8.5 * MedScheduleScreen.hourHeight, 0.001),
      );
    });
  });

  group('MedScheduleScreen — day cycling', () {
    testWidgets('Tomorrow / Yesterday chips relabel the displayed day',
        (WidgetTester tester) async {
      await _pumpScreen(tester, repo: repo);

      String label() =>
          tester.widget<Text>(find.byKey(MedScheduleScreen.dayLabelKey)).data!;

      expect(label(), 'Today');

      await tester.tap(find.byKey(MedScheduleScreen.nextDayKey));
      await tester.pumpAndSettle();
      expect(label(), 'Tomorrow');

      await tester.tap(find.byKey(MedScheduleScreen.prevDayKey));
      await tester.tap(find.byKey(MedScheduleScreen.prevDayKey));
      await tester.pumpAndSettle();
      expect(label(), 'Yesterday');
    });

    testWidgets('days more than one away show the weekday name',
        (WidgetTester tester) async {
      await _pumpScreen(tester, repo: repo);

      // Today is Sat May 30 2026; +2 days lands on Monday June 1.
      await tester.tap(find.byKey(MedScheduleScreen.nextDayKey));
      await tester.tap(find.byKey(MedScheduleScreen.nextDayKey));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(MedScheduleScreen.dayLabelKey)).data,
        'Monday',
      );
    });

    testWidgets('cycling days re-queries the doses shown',
        (WidgetTester tester) async {
      // A daily med visible every day, plus one whose schedule only
      // starts tomorrow — it must be absent today, present tomorrow.
      final DateTime tomorrow = DateTime(2026, 5, 31);
      await repo.upsertMedication(_med(id: 'daily', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('s-daily', 'daily', hour: 9));
      await repo.upsertMedication(_med(id: 'new', name: 'Sertraline'));
      await repo.upsertSchedule(
        _dailyAt('s-new', 'new', hour: 10, startsOn: tomorrow),
      );

      await _pumpScreen(tester, repo: repo);

      // Today: only the daily med's 9 AM marker.
      expect(
        find.byKey(
            MedScheduleScreen.markerKey('daily', DateTime(2026, 5, 30, 9))),
        findsOneWidget,
      );
      expect(
        find.byKey(
            MedScheduleScreen.markerKey('new', DateTime(2026, 5, 31, 10))),
        findsNothing,
      );

      await tester.tap(find.byKey(MedScheduleScreen.nextDayKey));
      await tester.pumpAndSettle();

      // Tomorrow: the new med's 10 AM marker appears.
      expect(
        find.byKey(
            MedScheduleScreen.markerKey('new', DateTime(2026, 5, 31, 10))),
        findsOneWidget,
      );
    });

    testWidgets('the "now" line shows only on today',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'a', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sa', 'a', hour: 9));

      await _pumpScreen(tester, repo: repo);
      expect(find.byKey(MedScheduleScreen.nowLineKey), findsOneWidget);

      await tester.tap(find.byKey(MedScheduleScreen.nextDayKey));
      await tester.pumpAndSettle();
      expect(find.byKey(MedScheduleScreen.nowLineKey), findsNothing);
    });
  });

  group('MedScheduleScreen — empty state', () {
    testWidgets('shows the no-doses message when nothing is scheduled',
        (WidgetTester tester) async {
      await _pumpScreen(tester, repo: repo);
      expect(find.byKey(MedScheduleScreen.emptyKey), findsOneWidget);
      expect(find.textContaining('No doses scheduled'), findsOneWidget);
    });
  });

  group('MedScheduleScreen — status resolution (reuses Home dot colors)', () {
    test('taken / late logs read as Taken (teal)', () {
      for (final DoseStatus s in <DoseStatus>[
        DoseStatus.taken,
        DoseStatus.late,
      ]) {
        final ScheduledDose dose = _dose(
          hour: 8,
          log: DoseLog(
            id: 'l',
            medicationId: 'm',
            scheduledFor: DateTime(2026, 5, 30, 8),
            status: s,
          ),
        );
        expect(medScheduleMarkerStatus(dose, _fixedNow()), 'Taken');
        expect(medScheduleMarkerColor(dose, _fixedNow()),
            MedicationsTodayCard.takenColor);
      }
    });

    test('a logged missed dose reads as Missed (coral)', () {
      final ScheduledDose dose = _dose(
        hour: 8,
        log: DoseLog(
          id: 'l',
          medicationId: 'm',
          scheduledFor: DateTime(2026, 5, 30, 8),
          status: DoseStatus.missed,
        ),
      );
      expect(medScheduleMarkerStatus(dose, _fixedNow()), 'Missed');
      expect(medScheduleMarkerColor(dose, _fixedNow()),
          MedicationsTodayCard.overdueColor);
    });

    test('an unlogged dose past "now" reads as Missed', () {
      final ScheduledDose dose = _dose(hour: 8); // 8 AM, now is 11 AM
      expect(medScheduleMarkerStatus(dose, _fixedNow()), 'Missed');
    });

    test('an unlogged dose still ahead of "now" reads as Due (amber)', () {
      final ScheduledDose dose = _dose(hour: 14); // 2 PM, now is 11 AM
      expect(medScheduleMarkerStatus(dose, _fixedNow()), 'Due');
      expect(medScheduleMarkerColor(dose, _fixedNow()),
          MedicationsTodayCard.dueSoonColor);
    });

    test('with no "now" reference (other days) an unlogged dose is Due', () {
      final ScheduledDose dose = _dose(hour: 8);
      expect(medScheduleMarkerStatus(dose, null), 'Due');
    });

    test('a skipped dose reads as Skipped (muted)', () {
      final ScheduledDose dose = _dose(
        hour: 8,
        log: DoseLog(
          id: 'l',
          medicationId: 'm',
          scheduledFor: DateTime(2026, 5, 30, 8),
          status: DoseStatus.skipped,
        ),
      );
      expect(medScheduleMarkerStatus(dose, _fixedNow()), 'Skipped');
      expect(medScheduleMarkerColor(dose, _fixedNow()),
          careblazersColors.primarySoft);
    });
  });
}

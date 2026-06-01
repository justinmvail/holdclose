import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../_semantics_matchers.dart';

/// Fixed "now" the in-memory [MedicationRepository] consults so the
/// screen queries the same day regardless of host wall clock. 11 AM on
/// Saturday May 30 2026 — after the morning 8 AM dose but before the
/// evening 8 PM one, so both an "after the late threshold" and an
/// "upcoming" row appear in the same render.
DateTime _fixedNow() => DateTime(2026, 5, 30, 11, 0);

/// Deterministic id factory: each call returns `id0`, `id1`, …
String Function() _counterFactory() {
  int n = 0;
  return () => 'log-id${n++}';
}

Medication _med({required String id, required String name}) => Medication(
      id: id,
      name: name,
      dosage: '10 mg',
      route: MedicationRoute.oral,
    );

DoseSchedule _dailyAt(String id, String medicationId, int hour) =>
    DoseSchedule(
      id: id,
      medicationId: medicationId,
      frequencyKind: FrequencyKind.daily,
      timesOfDay: <TimeOfDay>[TimeOfDay(hour: hour, minute: 0)],
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 5, 1),
    );

Future<({MedicationRepository repo, CareblazersDatabase db})> _pumpScreen(
  WidgetTester tester, {
  required MedicationRepository repo,
  required CareblazersDatabase db,
  String Function()? idFactory,
  String? initialNote,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/medications/today',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medications/today',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            DoseLogScreen(initialNote: initialNote),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        doseLogClockProvider.overrideWithValue(_fixedNow),
        doseLogIdFactoryProvider
            .overrideWithValue(idFactory ?? _counterFactory()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (repo: repo, db: db);
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

  group('DoseLogScreen — TASKS.md Phase 12.4 empty state', () {
    testWidgets('renders the "nothing scheduled" placeholder when no doses',
        (WidgetTester tester) async {
      await _pumpScreen(tester, repo: repo, db: db);

      expect(find.byKey(DoseLogScreen.emptyStateKey), findsOneWidget);
      expect(find.byKey(DoseLogScreen.listKey), findsNothing);
      expect(find.byKey(DoseLogScreen.bulkMorningButtonKey), findsNothing);
      expect(find.textContaining('Nothing scheduled today'), findsOneWidget);
    });

    testWidgets('AppBar title is "Today\'s doses"',
        (WidgetTester tester) async {
      await _pumpScreen(tester, repo: repo, db: db);
      expect(find.widgetWithText(AppBar, "Today's doses"), findsOneWidget);
    });
  });

  group('DoseLogScreen — mixed status rendering', () {
    testWidgets('renders one row per scheduled dose in chronological order',
        (WidgetTester tester) async {
      // Two meds, three doses today: 8 AM (Donepezil, missed log row),
      // 12 PM (Sertraline, upcoming), 8 PM (Memantine, upcoming).
      await repo.upsertMedication(_med(id: 'med-donepezil', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-don', 'med-donepezil', 8));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-don-missed',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 30, 8),
        status: DoseStatus.missed,
      ));

      await repo.upsertMedication(_med(id: 'med-sertraline', name: 'Sertraline'));
      await repo.upsertSchedule(_dailyAt('sched-sert', 'med-sertraline', 12));

      await repo.upsertMedication(_med(id: 'med-memantine', name: 'Memantine'));
      await repo.upsertSchedule(_dailyAt('sched-mem', 'med-memantine', 20));

      await _pumpScreen(tester, repo: repo, db: db);

      // All three rows present.
      expect(
        find.byKey(DoseLogScreen.rowKey(
            'med-donepezil', DateTime(2026, 5, 30, 8))),
        findsOneWidget,
      );
      expect(
        find.byKey(DoseLogScreen.rowKey(
            'med-sertraline', DateTime(2026, 5, 30, 12))),
        findsOneWidget,
      );
      expect(
        find.byKey(DoseLogScreen.rowKey(
            'med-memantine', DateTime(2026, 5, 30, 20))),
        findsOneWidget,
      );

      // Chronological top-to-bottom ordering.
      double y(Key k) => tester.getTopLeft(find.byKey(k)).dy;
      expect(
        y(DoseLogScreen.rowKey('med-donepezil', DateTime(2026, 5, 30, 8))),
        lessThan(y(DoseLogScreen.rowKey(
            'med-sertraline', DateTime(2026, 5, 30, 12)))),
      );
      expect(
        y(DoseLogScreen.rowKey('med-sertraline', DateTime(2026, 5, 30, 12))),
        lessThan(y(DoseLogScreen.rowKey(
            'med-memantine', DateTime(2026, 5, 30, 20)))),
      );

      // Clock formatting (matches the per-row time chip).
      expect(find.text('8:00 AM'), findsOneWidget);
      expect(find.text('12:00 PM'), findsOneWidget);
      expect(find.text('8:00 PM'), findsOneWidget);
    });

    testWidgets('upcoming dose shows the Mark taken CTA; logged dose does not',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 8));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-taken',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 30, 8),
        takenAt: DateTime(2026, 5, 30, 8, 2),
        status: DoseStatus.taken,
      ));
      // Second med, no log → upcoming.
      await repo.upsertMedication(_med(id: 'med-2', name: 'Memantine'));
      await repo.upsertSchedule(_dailyAt('sched-2', 'med-2', 20));

      await _pumpScreen(tester, repo: repo, db: db);

      // Logged dose has no Mark-taken button.
      expect(
        find.byKey(DoseLogScreen.markTakenButtonKey(
            'med-1', DateTime(2026, 5, 30, 8))),
        findsNothing,
      );
      // Upcoming dose has one.
      expect(
        find.byKey(DoseLogScreen.markTakenButtonKey(
            'med-2', DateTime(2026, 5, 30, 20))),
        findsOneWidget,
      );
    });

    testWidgets('renders Late badge for a DoseStatus.late row',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 8));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-late',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 30, 8),
        takenAt: DateTime(2026, 5, 30, 10, 30),
        status: DoseStatus.late,
      ));

      await _pumpScreen(tester, repo: repo, db: db);

      expect(
        find.byKey(DoseLogScreen.lateBadgeKey(
            'med-1', DateTime(2026, 5, 30, 8))),
        findsOneWidget,
      );
      expect(find.text('Late'), findsOneWidget);
    });

    testWidgets('skipped + missed statuses surface their text labels',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-skip', name: 'Sertraline'));
      await repo.upsertSchedule(_dailyAt('sched-skip', 'med-skip', 9));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-skip',
        medicationId: 'med-skip',
        scheduledFor: DateTime(2026, 5, 30, 9),
        status: DoseStatus.skipped,
      ));

      await repo.upsertMedication(_med(id: 'med-miss', name: 'Memantine'));
      await repo.upsertSchedule(_dailyAt('sched-miss', 'med-miss', 10));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-miss',
        medicationId: 'med-miss',
        scheduledFor: DateTime(2026, 5, 30, 10),
        status: DoseStatus.missed,
      ));

      await _pumpScreen(tester, repo: repo, db: db);

      expect(find.text('Skipped'), findsOneWidget);
      expect(find.text('Missed'), findsOneWidget);
    });
  });

  group('DoseLogScreen — Mark taken CTA writes a DoseLog', () {
    testWidgets('records a fresh DoseStatus.taken when within the window',
        (WidgetTester tester) async {
      // Schedule at 11 AM, fixed-now is 11 AM → elapsed = 0, < threshold.
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 11));

      await _pumpScreen(tester, repo: repo, db: db);

      await tester.tap(find.byKey(DoseLogScreen.markTakenButtonKey(
          'med-1', DateTime(2026, 5, 30, 11))));
      await tester.pumpAndSettle();

      final List<DoseLog> logs = await repo.logsFor('med-1');
      expect(logs, hasLength(1));
      expect(logs.single.status, DoseStatus.taken);
      expect(logs.single.scheduledFor, DateTime(2026, 5, 30, 11));
      expect(logs.single.takenAt, _fixedNow());
      // Row flipped — the CTA is gone, the status label is visible.
      expect(
        find.byKey(DoseLogScreen.markTakenButtonKey(
            'med-1', DateTime(2026, 5, 30, 11))),
        findsNothing,
      );
      expect(find.text('Taken'), findsOneWidget);
    });

    testWidgets('records DoseStatus.late when more than 30 min past schedule',
        (WidgetTester tester) async {
      // 8 AM schedule, fixed-now is 11 AM → 3 hours late.
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 8));

      await _pumpScreen(tester, repo: repo, db: db);

      await tester.tap(find.byKey(DoseLogScreen.markTakenButtonKey(
          'med-1', DateTime(2026, 5, 30, 8))));
      await tester.pumpAndSettle();

      final List<DoseLog> logs = await repo.logsFor('med-1');
      expect(logs.single.status, DoseStatus.late);
      // Late badge now renders on the row.
      expect(
        find.byKey(DoseLogScreen.lateBadgeKey(
            'med-1', DateTime(2026, 5, 30, 8))),
        findsOneWidget,
      );
    });
  });

  group('DoseLogScreen — voice-intake dose note (Phase 14.14)', () {
    testWidgets('no note field when opened without an initial note',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 11));

      await _pumpScreen(tester, repo: repo, db: db);

      expect(find.byKey(DoseLogScreen.noteFieldKey), findsNothing);
    });

    testWidgets('pre-fills the note field with the transcript',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 11));

      await _pumpScreen(
        tester,
        repo: repo,
        db: db,
        initialNote: 'gave it with breakfast',
      );

      final TextField field = tester.widget<TextField>(
        find.byKey(DoseLogScreen.noteFieldKey),
      );
      expect(field.controller?.text, 'gave it with breakfast');
    });

    testWidgets('marking a dose taken saves the note on the DoseLog',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 11));

      await _pumpScreen(
        tester,
        repo: repo,
        db: db,
        initialNote: 'gave it with breakfast',
      );

      await tester.tap(find.byKey(DoseLogScreen.markTakenButtonKey(
          'med-1', DateTime(2026, 5, 30, 11))));
      await tester.pumpAndSettle();

      final List<DoseLog> logs = await repo.logsFor('med-1');
      expect(logs.single.status, DoseStatus.taken);
      expect(logs.single.notes, 'gave it with breakfast');
    });

    testWidgets('an edited note rides along with the dose marked taken',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 11));

      await _pumpScreen(
        tester,
        repo: repo,
        db: db,
        initialNote: 'gave it with breakfast',
      );

      await tester.enterText(
        find.byKey(DoseLogScreen.noteFieldKey),
        'crushed into applesauce',
      );
      await tester.tap(find.byKey(DoseLogScreen.markTakenButtonKey(
          'med-1', DateTime(2026, 5, 30, 11))));
      await tester.pumpAndSettle();

      final List<DoseLog> logs = await repo.logsFor('med-1');
      expect(logs.single.notes, 'crushed into applesauce');
    });
  });

  group('DoseLogScreen — change status on a logged dose', () {
    testWidgets('tapping a logged row opens the status sheet',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 8));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-taken',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 30, 8),
        takenAt: DateTime(2026, 5, 30, 8, 2),
        status: DoseStatus.taken,
      ));

      await _pumpScreen(tester, repo: repo, db: db);

      await tester.tap(find.byKey(
          DoseLogScreen.rowKey('med-1', DateTime(2026, 5, 30, 8))));
      await tester.pumpAndSettle();

      // Every status option is in the tree.
      for (final DoseStatus s in DoseStatus.values) {
        expect(find.byKey(DoseLogScreen.statusSheetOptionKey(s)),
            findsOneWidget);
      }
    });

    testWidgets('taken → late updates the underlying DoseLog row in place',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 8));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-original',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 30, 8),
        takenAt: DateTime(2026, 5, 30, 8, 2),
        status: DoseStatus.taken,
      ));

      await _pumpScreen(tester, repo: repo, db: db);

      await tester.tap(find.byKey(
          DoseLogScreen.rowKey('med-1', DateTime(2026, 5, 30, 8))));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(DoseLogScreen.statusSheetOptionKey(DoseStatus.late)));
      await tester.pumpAndSettle();

      final List<DoseLog> logs = await repo.logsFor('med-1');
      expect(logs, hasLength(1), reason: 'no new row should be inserted');
      expect(logs.single.id, 'log-original');
      expect(logs.single.status, DoseStatus.late);
      // Late badge surfaces on the next render.
      expect(
        find.byKey(DoseLogScreen.lateBadgeKey(
            'med-1', DateTime(2026, 5, 30, 8))),
        findsOneWidget,
      );
    });

    testWidgets('skipped → taken stamps takenAt with the current clock',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 9));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-skipped',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 30, 9),
        status: DoseStatus.skipped,
      ));

      await _pumpScreen(tester, repo: repo, db: db);

      await tester.tap(find.byKey(
          DoseLogScreen.rowKey('med-1', DateTime(2026, 5, 30, 9))));
      await tester.pumpAndSettle();
      // 9 AM scheduled + 11 AM "now" → past the 30-min late threshold,
      // but the caregiver explicitly picked "Taken", so the log's
      // status should be exactly DoseStatus.taken — the cycle from
      // skipped reuses the explicit choice rather than auto-promoting.
      await tester.tap(
          find.byKey(DoseLogScreen.statusSheetOptionKey(DoseStatus.taken)));
      await tester.pumpAndSettle();

      final List<DoseLog> logs = await repo.logsFor('med-1');
      expect(logs.single.status, DoseStatus.taken);
      expect(logs.single.takenAt, _fixedNow());
    });

    testWidgets('taken → skipped clears takenAt',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 8));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-1',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 30, 8),
        takenAt: DateTime(2026, 5, 30, 8, 2),
        status: DoseStatus.taken,
      ));

      await _pumpScreen(tester, repo: repo, db: db);

      await tester.tap(find.byKey(
          DoseLogScreen.rowKey('med-1', DateTime(2026, 5, 30, 8))));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(DoseLogScreen.statusSheetOptionKey(DoseStatus.skipped)));
      await tester.pumpAndSettle();

      final List<DoseLog> logs = await repo.logsFor('med-1');
      expect(logs.single.status, DoseStatus.skipped);
      expect(logs.single.takenAt, isNull);
    });
  });

  group('DoseLogScreen — bulk "Mark all before noon taken"', () {
    testWidgets('button hidden when no pending morning doses exist',
        (WidgetTester tester) async {
      // Single afternoon dose, no morning rows.
      await repo.upsertMedication(_med(id: 'med-1', name: 'Memantine'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 20));

      await _pumpScreen(tester, repo: repo, db: db);

      expect(find.byKey(DoseLogScreen.bulkMorningButtonKey), findsNothing);
    });

    testWidgets('button hidden when every morning dose is already taken',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 8));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-taken',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 30, 8),
        takenAt: DateTime(2026, 5, 30, 8, 2),
        status: DoseStatus.taken,
      ));

      await _pumpScreen(tester, repo: repo, db: db);

      expect(find.byKey(DoseLogScreen.bulkMorningButtonKey), findsNothing);
    });

    testWidgets('button marks every pending morning dose taken in one tap',
        (WidgetTester tester) async {
      // Three morning meds (8, 9, 10 AM) all pending + one afternoon
      // med (8 PM) the bulk action MUST leave alone.
      await repo.upsertMedication(_med(id: 'med-a', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-a', 'med-a', 8));
      await repo.upsertMedication(_med(id: 'med-b', name: 'Sertraline'));
      await repo.upsertSchedule(_dailyAt('sched-b', 'med-b', 9));
      await repo.upsertMedication(_med(id: 'med-c', name: 'Galantamine'));
      await repo.upsertSchedule(_dailyAt('sched-c', 'med-c', 10));
      await repo.upsertMedication(_med(id: 'med-d', name: 'Memantine'));
      await repo.upsertSchedule(_dailyAt('sched-d', 'med-d', 20));

      await _pumpScreen(tester, repo: repo, db: db);

      expect(find.byKey(DoseLogScreen.bulkMorningButtonKey), findsOneWidget);
      await tester.tap(find.byKey(DoseLogScreen.bulkMorningButtonKey));
      await tester.pumpAndSettle();

      // Every morning dose got a log row; the afternoon dose did not.
      expect((await repo.logsFor('med-a')), hasLength(1));
      expect((await repo.logsFor('med-b')), hasLength(1));
      expect((await repo.logsFor('med-c')), hasLength(1));
      expect((await repo.logsFor('med-d')), isEmpty);

      // Statuses reflect the late-threshold rule: 11 AM "now" makes the
      // 8 / 9 / 10 AM rows all > 30 min late.
      for (final String id in <String>['med-a', 'med-b', 'med-c']) {
        expect((await repo.logsFor(id)).single.status, DoseStatus.late,
            reason: '$id was logged > 30 min past schedule');
      }
      // The button hides on re-render since no morning row is pending.
      expect(find.byKey(DoseLogScreen.bulkMorningButtonKey), findsNothing);
    });

    testWidgets('bulk action upgrades a missed log into taken/late',
        (WidgetTester tester) async {
      // One morning med with an existing "missed" log — the bulk path
      // treats missed as pending and rewrites the same log id.
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 8));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-missed-original',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 30, 8),
        status: DoseStatus.missed,
      ));

      await _pumpScreen(tester, repo: repo, db: db);

      await tester.tap(find.byKey(DoseLogScreen.bulkMorningButtonKey));
      await tester.pumpAndSettle();

      final List<DoseLog> logs = await repo.logsFor('med-1');
      expect(logs, hasLength(1),
          reason: 'should reuse the missed row id, not duplicate it');
      expect(logs.single.id, 'log-missed-original');
      expect(logs.single.status, DoseStatus.late);
    });
  });

  group('DoseLogScreen — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets('upcoming rows announce mark-taken affordance',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 12));

      await _pumpScreen(tester, repo: repo, db: db);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Donepezil.*10 mg.*Not yet logged.*Double-tap to mark taken'),
        ),
        isTrue,
      );
    });

    testWidgets('logged rows announce current status + change affordance',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_dailyAt('sched-1', 'med-1', 8));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-late',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 30, 8),
        takenAt: DateTime(2026, 5, 30, 10, 30),
        status: DoseStatus.late,
      ));

      await _pumpScreen(tester, repo: repo, db: db);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Donepezil.*Status: Taken late.*Double-tap to change'),
        ),
        isTrue,
      );
    });
  });

  group('markTakenStatusFor helper', () {
    test('on-time tap returns DoseStatus.taken', () {
      expect(
        markTakenStatusFor(
            DateTime(2026, 5, 30, 8), DateTime(2026, 5, 30, 8, 15)),
        DoseStatus.taken,
      );
    });

    test('tap before the scheduled time returns DoseStatus.taken', () {
      expect(
        markTakenStatusFor(
            DateTime(2026, 5, 30, 8), DateTime(2026, 5, 30, 7, 55)),
        DoseStatus.taken,
      );
    });

    test('tap > 30 min past schedule returns DoseStatus.late', () {
      expect(
        markTakenStatusFor(
            DateTime(2026, 5, 30, 8), DateTime(2026, 5, 30, 9)),
        DoseStatus.late,
      );
    });
  });
}

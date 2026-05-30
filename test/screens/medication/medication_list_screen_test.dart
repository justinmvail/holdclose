import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medication/medication_form_screen.dart';
import 'package:careblazers/screens/medication/medication_list_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../_semantics_matchers.dart';

/// Fixed "now" the in-memory [MedicationRepository] consults so the
/// "Today / Tomorrow" formatting is deterministic across hosts. Pinned
/// to Saturday so the next 7-day window covers a Sun-Sat span without
/// crossing a DST boundary in the standard test timezones.
DateTime _fixedNow() => DateTime(2026, 5, 30, 6, 0);

Medication _med({
  required String id,
  required String name,
  String dosage = '10 mg',
}) =>
    Medication(
      id: id,
      name: name,
      dosage: dosage,
      route: MedicationRoute.oral,
    );

DoseSchedule _daily8am(String id, String medicationId) => DoseSchedule(
      id: id,
      medicationId: medicationId,
      frequencyKind: FrequencyKind.daily,
      timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 5, 1),
    );

Future<({
  GoRouter router,
  MedicationRepository repo,
  List<String> pushedPaths,
  CareblazersDatabase db,
})> _pumpList(
  WidgetTester tester, {
  required MedicationRepository repo,
  required CareblazersDatabase db,
  Size surfaceSize = const Size(420, 1000),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> pushedPaths = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/medications',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const MedicationListScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) {
              pushedPaths.add('/medications/new');
              return const Scaffold(body: Center(child: Text('form-stub')));
            },
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      // Fresh-keyed so a subsequent `_pumpList` call (the form
      // round-trip test) tears down + remounts a new scope rather
      // than trying to update the prior scope in place (Riverpod
      // forbids changing override counts on an existing scope).
      key: UniqueKey(),
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        medicationListClockProvider.overrideWithValue(_fixedNow),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  return (router: router, repo: repo, pushedPaths: pushedPaths, db: db);
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

  group('MedicationListScreen — TASKS.md Phase 12.3 empty state', () {
    testWidgets('renders the empty-state CTA when no medications exist',
        (WidgetTester tester) async {
      await _pumpList(tester, repo: repo, db: db);

      expect(find.byKey(MedicationListScreen.emptyStateKey), findsOneWidget);
      expect(find.byKey(MedicationListScreen.emptyCtaKey), findsOneWidget);
      // FAB is hidden while empty — the inline CTA replaces it.
      expect(find.byKey(MedicationListScreen.fabKey), findsNothing);
      expect(find.byKey(MedicationListScreen.listKey), findsNothing);
    });

    testWidgets('tapping the empty-state CTA pushes /medications/new',
        (WidgetTester tester) async {
      final p = await _pumpList(tester, repo: repo, db: db);

      await tester.tap(find.byKey(MedicationListScreen.emptyCtaKey));
      await tester.pumpAndSettle();

      expect(p.pushedPaths, <String>['/medications/new']);
    });

    testWidgets('AppBar title is "Medications"',
        (WidgetTester tester) async {
      await _pumpList(tester, repo: repo, db: db);
      expect(find.widgetWithText(AppBar, 'Medications'), findsOneWidget);
    });
  });

  group('MedicationListScreen — single medication', () {
    testWidgets('renders one card with name + dosage + next dose subtitle',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_daily8am('sched-1', 'med-1'));

      await _pumpList(tester, repo: repo, db: db);

      expect(find.byKey(MedicationListScreen.tileKey('med-1')),
          findsOneWidget);
      expect(find.text('Donepezil'), findsOneWidget);
      expect(find.text('10 mg'), findsOneWidget);
      // Next dose is today at 8 AM (clock is 6 AM same day).
      expect(
        find.descendant(
          of: find.byKey(MedicationListScreen.nextDoseKey('med-1')),
          matching: find.textContaining('Today, 8:00 AM'),
        ),
        findsOneWidget,
      );
      // FAB visible whenever the list is populated.
      expect(find.byKey(MedicationListScreen.fabKey), findsOneWidget);
      // Empty-state CTA replaced by the FAB.
      expect(find.byKey(MedicationListScreen.emptyCtaKey), findsNothing);
    });

    testWidgets('a medication with no schedule shows the "no upcoming" '
        'fallback subtitle', (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-prn', name: 'Acetaminophen'));

      await _pumpList(tester, repo: repo, db: db);

      expect(
        find.descendant(
          of: find.byKey(MedicationListScreen.nextDoseKey('med-prn')),
          matching: find.textContaining('No upcoming dose'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('adherence chip shows "—" when no scoreable history yet',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_daily8am('sched-1', 'med-1'));

      await _pumpList(tester, repo: repo, db: db);

      expect(
        find.descendant(
          of: find.byKey(MedicationListScreen.adherenceChipKey('med-1')),
          matching: find.text('—'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('adherence chip surfaces a percentage when logs exist',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_daily8am('sched-1', 'med-1'));
      // Two doses in the trailing 7-day window: one taken, one missed.
      // Clock is 2026-05-30 06:00 — window starts 2026-05-23 06:00.
      await repo.upsertDoseLog(DoseLog(
        id: 'log-taken',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 25, 8),
        takenAt: DateTime(2026, 5, 25, 8, 2),
        status: DoseStatus.taken,
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-missed',
        medicationId: 'med-1',
        scheduledFor: DateTime(2026, 5, 26, 8),
        status: DoseStatus.missed,
      ));

      await _pumpList(tester, repo: repo, db: db);

      // The window is 7 days back from 2026-05-30 06:00 — daily 8am
      // schedule produced 7 scheduled doses (May 23–29 at 8 AM, all
      // after the 06:00 window start; May 30 8 AM is outside the
      // window end), of which 1 is taken, 1 explicitly missed, and 5
      // are implicit-missed (no log row). Numerator 1, denominator 7.
      final int pct = ((1 / 7) * 100).round();
      expect(
        find.descendant(
          of: find.byKey(MedicationListScreen.adherenceChipKey('med-1')),
          matching: find.text('$pct%'),
        ),
        findsOneWidget,
      );
    });
  });

  group('MedicationListScreen — 10 medications', () {
    testWidgets('renders one tile per medication in alphabetical order',
        (WidgetTester tester) async {
      // Names chosen so alphabetical != insertion order — proves the
      // list is reading through `repo.listMedications()`'s sort.
      const List<String> names = <String>[
        'Atorvastatin',
        'Citalopram',
        'Donepezil',
        'Galantamine',
        'Lisinopril',
        'Memantine',
        'Metformin',
        'Quetiapine',
        'Rivastigmine',
        'Sertraline',
      ];
      // Insert in reverse so the rendering test must rely on the sort.
      for (int i = names.length - 1; i >= 0; i--) {
        final String id = 'med-${i.toString().padLeft(2, '0')}';
        await repo.upsertMedication(_med(id: id, name: names[i]));
        await repo.upsertSchedule(_daily8am('sched-$i', id));
      }

      await _pumpList(
        tester,
        repo: repo,
        db: db,
        surfaceSize: const Size(420, 2400),
      );

      // Every tile is in the tree (within the tall test surface).
      for (int i = 0; i < names.length; i++) {
        final String id = 'med-${i.toString().padLeft(2, '0')}';
        expect(
          find.byKey(MedicationListScreen.tileKey(id)),
          findsOneWidget,
          reason: 'tile for $id should render',
        );
      }

      // Verify visual top-to-bottom ordering matches alphabetical.
      double y(String id) => tester
          .getTopLeft(find.byKey(MedicationListScreen.tileKey(id)))
          .dy;
      for (int i = 1; i < names.length; i++) {
        final String prevId = 'med-${(i - 1).toString().padLeft(2, '0')}';
        final String thisId = 'med-${i.toString().padLeft(2, '0')}';
        expect(y(prevId), lessThan(y(thisId)),
            reason: '${names[i - 1]} should render above ${names[i]}');
      }
    });

    testWidgets('FAB pushes /medications/new from the populated list',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_daily8am('sched-1', 'med-1'));

      final p = await _pumpList(tester, repo: repo, db: db);

      await tester.tap(find.byKey(MedicationListScreen.fabKey));
      await tester.pumpAndSettle();

      expect(p.pushedPaths, <String>['/medications/new']);
    });
  });

  group('MedicationListScreen — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets('the empty-state CTA carries a screen-reader label',
        (WidgetTester tester) async {
      await _pumpList(tester, repo: repo, db: db);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Add a medication.*Open the add-medication form'),
        ),
        isTrue,
      );
    });

    testWidgets('each populated tile announces name + dosage + adherence',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med(id: 'med-1', name: 'Donepezil'));
      await repo.upsertSchedule(_daily8am('sched-1', 'med-1'));

      await _pumpList(tester, repo: repo, db: db);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Donepezil.*10 mg.*Adherence.*last 7 days'),
        ),
        isTrue,
      );
    });
  });

  group('MedicationListScreen — form round-trip', () {
    testWidgets('list reflects a new medication after the form inserts one',
        (WidgetTester tester) async {
      // Pump 1: empty list confirms the starting state.
      await _pumpList(tester, repo: repo, db: db);
      expect(find.byKey(MedicationListScreen.emptyStateKey), findsOneWidget);

      // Insert through the shared repo the way the form's submit path
      // would, then re-pump a fresh widget tree wired to the same repo.
      // The list provider is `keepAlive: false` so a fresh pump re-runs
      // the future against the now-populated repo — mirrors what the
      // form's `ref.invalidate(medicationListProvider)` would trigger.
      await repo.upsertMedication(_med(id: 'med-new', name: 'Memantine'));
      await repo.upsertSchedule(_daily8am('sched-new', 'med-new'));

      await _pumpList(tester, repo: repo, db: db);

      expect(find.byKey(MedicationListScreen.tileKey('med-new')),
          findsOneWidget);
      expect(find.text('Memantine'), findsOneWidget);
    });
  });

  group('MedicationFormScreen route registration sanity', () {
    testWidgets('/medications/new mounts MedicationFormScreen', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final GoRouter router = GoRouter(
        initialLocation: '/medications/new',
        routes: <RouteBase>[
          GoRoute(
            path: '/medications/new',
            builder: (BuildContext context, GoRouterState state) =>
                const MedicationFormScreen(),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            medicationRepositoryBackendProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(MedicationFormScreen), findsOneWidget);
    });
  });
}

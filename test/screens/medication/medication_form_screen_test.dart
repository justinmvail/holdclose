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

/// Fixed "now" so the default schedule's `startsOn` is deterministic.
DateTime _fixedNow() => DateTime(2026, 5, 30, 9, 0);

/// Deterministic id factory: each call returns `id0`, `id1`, … so the
/// form mints `med-id0` for the medication and `sched-id1` for its
/// default schedule.
String Function() _counterFactory() {
  int n = 0;
  return () => 'id${n++}';
}

Future<({
  GoRouter router,
  MedicationRepository repo,
  CareblazersDatabase db,
  List<String> popped,
})> _pumpForm(
  WidgetTester tester, {
  required MedicationRepository repo,
  required CareblazersDatabase db,
  String Function()? idFactory,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> popped = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/medications/new',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) {
          popped.add('/medications');
          return const Scaffold(body: Center(child: Text('list-stub')));
        },
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                const MedicationFormScreen(),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        medicationFormClockProvider.overrideWithValue(_fixedNow),
        medicationFormIdFactoryProvider
            .overrideWithValue(idFactory ?? _counterFactory()),
        // The form invalidates `medicationListProvider` on submit; make
        // sure a list-clock override is in scope so the (unrendered)
        // re-resolve doesn't fall back to the real wall clock.
        medicationListClockProvider.overrideWithValue(_fixedNow),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  return (router: router, repo: repo, db: db, popped: popped);
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

  group('MedicationFormScreen — TASKS.md Phase 12.3 validation', () {
    testWidgets('submit with an empty name surfaces the "Name is required" '
        'error and does not insert', (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, db: db);

      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Name is required.'), findsOneWidget);
      expect(await repo.listMedications(), isEmpty);
    });

    testWidgets('submit with name but empty dosage surfaces dosage error',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, db: db);

      await tester.enterText(
        find.byKey(MedicationFormScreen.nameFieldKey),
        'Donepezil',
      );
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Dosage is required.'), findsOneWidget);
      expect(await repo.listMedications(), isEmpty);
    });

    testWidgets(
        'whitespace-only name still surfaces the required-field error',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, db: db);

      await tester.enterText(
        find.byKey(MedicationFormScreen.nameFieldKey),
        '   ',
      );
      await tester.enterText(
        find.byKey(MedicationFormScreen.dosageFieldKey),
        '10 mg',
      );
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Name is required.'), findsOneWidget);
      expect(await repo.listMedications(), isEmpty);
    });
  });

  group('MedicationFormScreen — happy-path round-trip', () {
    testWidgets('submit inserts a Medication + default daily 8 AM schedule',
        (WidgetTester tester) async {
      final p = await _pumpForm(tester, repo: repo, db: db);

      await tester.enterText(
        find.byKey(MedicationFormScreen.nameFieldKey),
        'Donepezil',
      );
      await tester.enterText(
        find.byKey(MedicationFormScreen.dosageFieldKey),
        '10 mg',
      );
      await tester.enterText(
        find.byKey(MedicationFormScreen.prescriberFieldKey),
        'Dr. Kim',
      );
      await tester.enterText(
        find.byKey(MedicationFormScreen.notesFieldKey),
        'Take with breakfast.',
      );
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      // Form popped back to /medications.
      expect(p.popped, contains('/medications'));

      // Repository now carries exactly the medication the form built.
      final List<Medication> meds = await repo.listMedications();
      expect(meds, hasLength(1));
      final Medication saved = meds.single;
      expect(saved.id, 'med-id0');
      expect(saved.name, 'Donepezil');
      expect(saved.dosage, '10 mg');
      expect(saved.route, MedicationRoute.oral);
      expect(saved.prescriber, 'Dr. Kim');
      expect(saved.notes, 'Take with breakfast.');

      // The default schedule is daily, single 8 AM dose, starts today.
      final List<DoseSchedule> schedules =
          await repo.schedulesFor('med-id0');
      expect(schedules, hasLength(1));
      final DoseSchedule sched = schedules.single;
      expect(sched.id, 'sched-id1');
      expect(sched.medicationId, 'med-id0');
      expect(sched.frequencyKind, FrequencyKind.daily);
      expect(sched.timesOfDay, <TimeOfDay>[
        const TimeOfDay(hour: 8, minute: 0),
      ]);
      expect(sched.startsOn, DateTime(2026, 5, 30));
    });

    testWidgets('empty optional fields persist as null on the model',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, db: db);

      await tester.enterText(
        find.byKey(MedicationFormScreen.nameFieldKey),
        'Memantine',
      );
      await tester.enterText(
        find.byKey(MedicationFormScreen.dosageFieldKey),
        '10 mg',
      );
      // Leave prescriber + notes untouched (empty).
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final Medication saved = (await repo.listMedications()).single;
      expect(saved.prescriber, isNull);
      expect(saved.notes, isNull);
    });

    testWidgets('changing the route dropdown is reflected on the saved row',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, db: db);

      await tester.enterText(
        find.byKey(MedicationFormScreen.nameFieldKey),
        'Estradiol',
      );
      await tester.enterText(
        find.byKey(MedicationFormScreen.dosageFieldKey),
        '0.05 mg/day',
      );
      // Open + select Topical.
      await tester.tap(find.byKey(MedicationFormScreen.routeDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Topical (patch / cream)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final Medication saved = (await repo.listMedications()).single;
      expect(saved.route, MedicationRoute.topical);
    });
  });

  group('MedicationFormScreen — list provider invalidation', () {
    testWidgets('after submit, a fresh list mount surfaces the new med', (
      WidgetTester tester,
    ) async {
      await _pumpForm(tester, repo: repo, db: db);

      await tester.enterText(
        find.byKey(MedicationFormScreen.nameFieldKey),
        'Donepezil',
      );
      await tester.enterText(
        find.byKey(MedicationFormScreen.dosageFieldKey),
        '10 mg',
      );
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      // Mount the list screen against the same repo — the freshly-
      // inserted medication should be the only tile. The
      // [UniqueKey] forces Flutter to mount a brand-new ProviderScope
      // rather than try to update the form's scope in place (Riverpod
      // refuses to add/remove overrides on an existing scope).
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: <Override>[
            medicationRepositoryBackendProvider.overrideWithValue(repo),
            medicationListClockProvider.overrideWithValue(_fixedNow),
          ],
          child: const MaterialApp(home: MedicationListScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Donepezil'), findsOneWidget);
      expect(find.byKey(MedicationListScreen.tileKey('med-id0')),
          findsOneWidget);
    });
  });
}

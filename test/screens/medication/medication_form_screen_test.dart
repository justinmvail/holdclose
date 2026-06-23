import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/medication/medication_form_screen.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/widgets/path_header.dart';
import 'package:holdclose/widgets/weekday_picker.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// End-to-end form coverage for the Medication add/edit/delete screen
/// (`/medications/new`, `/medications/:id/edit`) — the core medication
/// editing surface that previously had only a golden snapshot. Drives the
/// real form against an in-memory repo: create, validation, edit + persist,
/// and delete.

DateTime _fixedNow() => DateTime(2026, 6, 4, 9, 0);

Medication _med(String id, String name,
        {String dosage = '10 mg', MedicationRoute route = MedicationRoute.oral}) =>
    Medication(id: id, name: name, dosage: dosage, route: route);

Future<MedicationRepository> _pumpForm(
  WidgetTester tester, {
  required MedicationRepository repo,
  String? editId,
  String idValue = '1',
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final String location =
      editId == null ? '/medications/new' : '/medications/$editId/edit';

  final GoRouter router = GoRouter(
    initialLocation: location,
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        parentNavigatorKey: rootKey,
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('list-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) =>
                const MedicationFormScreen(),
          ),
          GoRoute(
            path: ':id/edit',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) =>
                MedicationFormScreen(medicationId: s.pathParameters['id']),
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
        medicationFormIdFactoryProvider.overrideWithValue(() => idValue),
        // The window multi-select reads doseWindowListProvider, which now
        // resolves its patient id via activePatientIdProvider →
        // storageProvider. An empty in-memory store keeps the test off
        // on-device sqlite and falls back to 'demo-patient-mary'.
        storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HoldcloseDatabase db;
  late MedicationRepository repo;

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
    repo = MedicationRepository(db, clock: _fixedNow);
  });

  tearDown(() async {
    await db.close();
  });

  group('MedicationFormScreen — create', () {
    testWidgets('fills the form, saves, persists, and pops to the list',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(MedicationFormScreen.nameFieldKey), 'Donepezil');
      await tester.enterText(
          find.byKey(MedicationFormScreen.dosageFieldKey), '10');
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final List<Medication> meds = await repo.listMedications();
      expect(meds, hasLength(1));
      final Medication saved = meds.single;
      expect(saved.id, 'med-1'); // minted from the fixed id factory
      expect(saved.name, 'Donepezil');
      expect(saved.dosage, '10 mg'); // amount + default unit composed
      expect(saved.route, MedicationRoute.oral);
      // Popped back to the medication list.
      expect(find.text('list-stub'), findsOneWidget);
    });
  });

  group('MedicationFormScreen — validation', () {
    testWidgets('an empty name is rejected and nothing persists',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(MedicationFormScreen.dosageFieldKey), '10');
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Name is required.'), findsOneWidget);
      expect(await repo.listMedications(), isEmpty);
      expect(find.text('list-stub'), findsNothing); // still on the form
    });

    testWidgets('an empty dosage is rejected and nothing persists',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(MedicationFormScreen.nameFieldKey), 'Donepezil');
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Dosage is required.'), findsOneWidget);
      expect(await repo.listMedications(), isEmpty);
    });

    testWidgets('a duplicate name is rejected and nothing new persists',
        (WidgetTester tester) async {
      // Alpha bug report (Judd): "Multiple medications with same name
      // allowed." Adding a second "Ibuprofen" must be blocked.
      await repo.upsertMedication(_med('med-existing', 'Ibuprofen'));
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(MedicationFormScreen.nameFieldKey), 'Ibuprofen');
      await tester.enterText(
          find.byKey(MedicationFormScreen.dosageFieldKey), '400');
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.textContaining('already have a medication named'),
          findsOneWidget);
      expect(await repo.listMedications(), hasLength(1)); // no new row
      expect(find.text('list-stub'), findsNothing); // still on the form
    });

    testWidgets('the duplicate-name check is case-insensitive',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med('med-existing', 'Ibuprofen'));
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(MedicationFormScreen.nameFieldKey), 'ibuprofen');
      await tester.enterText(
          find.byKey(MedicationFormScreen.dosageFieldKey), '200');
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.textContaining('already have a medication named'),
          findsOneWidget);
      expect(await repo.listMedications(), hasLength(1));
    });
  });

  group('MedicationFormScreen — edit', () {
    testWidgets('hydrates the existing med, edits the dosage, updates in place',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med('med-9', 'Donepezil', dosage: '10 mg'));

      await _pumpForm(tester, repo: repo, editId: 'med-9');

      // Hydrated values land in the fields.
      expect(find.text('Donepezil'), findsOneWidget);
      expect(find.text('10'), findsOneWidget); // amount split from "10 mg"

      await tester.enterText(
          find.byKey(MedicationFormScreen.dosageFieldKey), '5');
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final List<Medication> meds = await repo.listMedications();
      expect(meds, hasLength(1)); // same row, no duplicate
      expect(meds.single.id, 'med-9');
      expect(meds.single.dosage, '5 mg');
      expect(meds.single.name, 'Donepezil'); // untouched
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('picking specific days persists daysOfWeek on the entry',
        (WidgetTester tester) async {
      // A med taken in a morning window, every day (entry days empty).
      await repo.upsertMedication(_med('med-d', 'Donepezil'));
      await repo.upsertWindow(const DoseWindow(
        id: 'w-morning',
        patientId: 'demo-patient-mary',
        label: 'Morning',
        anchorTime: TimeOfDay(hour: 8, minute: 0),
        sortOrder: 0,
      ));
      await repo.upsertEntry(MedicationWindowEntry(
        id: 'e-1',
        medicationId: 'med-d',
        windowId: 'w-morning',
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 1, 1),
      ));

      await _pumpForm(tester, repo: repo, editId: 'med-d');

      // The day picker hydrates to "every day"; drop Tuesday (weekday 2).
      await tester.ensureVisible(find.byKey(WeekdayPicker.chipKey(2)));
      await tester.tap(find.byKey(WeekdayPicker.chipKey(2)));
      await tester.pumpAndSettle();

      await tester
          .ensureVisible(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.tap(find.byKey(MedicationFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      // The entry now fires Mon + Wed–Sun, reusing its id + start date.
      final List<MedicationWindowEntry> entries =
          await repo.entriesForMedication('med-d');
      expect(entries, hasLength(1));
      expect(entries.single.daysOfWeek, <int>{1, 3, 4, 5, 6, 7});
      expect(entries.single.id, 'e-1');
      expect(entries.single.startsOn, DateTime(2026, 1, 1));
    });
  });

  group('MedicationFormScreen — delete', () {
    testWidgets('delete is edit-only, confirms, then removes the med',
        (WidgetTester tester) async {
      // Add path: no delete affordance.
      await _pumpForm(tester, repo: repo);
      expect(find.byKey(MedicationFormScreen.deleteButtonKey), findsNothing);

      // Edit path: delete confirms then soft-deletes (drops from the list).
      await repo.upsertMedication(_med('med-7', 'Ibuprofen'));
      await _pumpForm(tester, repo: repo, editId: 'med-7');
      expect(find.byKey(MedicationFormScreen.deleteButtonKey), findsOneWidget);

      await tester.tap(find.byKey(MedicationFormScreen.deleteButtonKey));
      await tester.pumpAndSettle();
      // Confirm dialog.
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(await repo.listMedications(), isEmpty);
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('cancelling the delete dialog keeps the med',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med('med-7', 'Ibuprofen'));
      await _pumpForm(tester, repo: repo, editId: 'med-7');

      await tester.tap(find.byKey(MedicationFormScreen.deleteButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(await repo.listMedications(), hasLength(1));
    });
  });

  group('MedicationFormScreen — PathHeader back affordance', () {
    // Regression for alpha bug fb_1780932762335231: the breadcrumb back
    // affordance must be present on every branch — including before the
    // hydration future resolves — so the screen is never swipe-only.
    testWidgets('renders the PathHeader breadcrumb on the loading branch',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(440, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final GoRouter router = GoRouter(
        initialLocation: '/medications/new',
        routes: <RouteBase>[
          GoRoute(
            path: '/medications/new',
            builder: (BuildContext c, GoRouterState s) =>
                const MedicationFormScreen(),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            medicationRepositoryBackendProvider.overrideWithValue(repo),
            medicationFormClockProvider.overrideWithValue(_fixedNow),
            medicationFormIdFactoryProvider.overrideWithValue(() => '1'),
            storageBackendProvider
                .overrideWithValue(InMemoryStorageProvider()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      // A single pump — the hydration future has NOT resolved yet, so this
      // is the loading branch. The PathHeader must already be on screen.
      await tester.pump();

      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Care'), findsOneWidget);
      expect(find.text('Medications'), findsOneWidget);
    });
  });
}

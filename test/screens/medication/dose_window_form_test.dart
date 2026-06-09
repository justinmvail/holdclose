import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medication/dose_window_list_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// End-to-end form coverage for the dose-window create/edit/delete form
/// (`/medications/windows/new`, `/medications/windows/:id`) — the surface
/// caregivers use to rename / re-anchor / delete the pillbox time slots.
/// Previously covered only by the windows-list golden; this drives the
/// real form against an in-memory repo: create, validation (empty +
/// duplicate label), edit + persist, delete, and the as-needed toggle.

const String _patientId = 'demo-patient-mary';

DateTime _fixedNow() => DateTime(2026, 6, 4, 9, 0);

DoseWindow _window(
  String id,
  String label, {
  TimeOfDay? anchor = const TimeOfDay(hour: 8, minute: 0),
  int sortOrder = 0,
}) =>
    DoseWindow(
      id: id,
      patientId: _patientId,
      label: label,
      anchorTime: anchor,
      sortOrder: sortOrder,
    );

Future<MedicationRepository> _pumpForm(
  WidgetTester tester, {
  required MedicationRepository repo,
  String? editId,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final String location = editId == null
      ? '/medications/windows/new'
      : '/medications/windows/$editId';

  final GoRouter router = GoRouter(
    initialLocation: location,
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medications/windows',
        parentNavigatorKey: rootKey,
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('list-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) =>
                const DoseWindowFormScreen(),
          ),
          GoRoute(
            path: ':id',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) =>
                DoseWindowFormScreen(windowId: s.pathParameters['id']),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        // The form resolves its patient id via activePatientIdProvider →
        // storageProvider; an empty in-memory store keeps the test off
        // on-device sqlite and falls back to 'demo-patient-mary' (the
        // windows here are keyed on it), so behaviour is unchanged.
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

  late CareblazersDatabase db;
  late MedicationRepository repo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = MedicationRepository(db, clock: _fixedNow);
  });

  tearDown(() async {
    await db.close();
  });

  group('DoseWindowFormScreen — create', () {
    testWidgets('fills label, saves, persists, and pops to the windows list',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(DoseWindowFormScreen.labelFieldKey), 'Lunchtime');
      await tester.tap(find.byKey(DoseWindowFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final List<DoseWindow> windows = await repo.windowsForPatient(_patientId);
      expect(windows, hasLength(1));
      final DoseWindow saved = windows.single;
      expect(saved.label, 'Lunchtime');
      // Default anchor (no time picker interaction) is 8:00 AM.
      expect(saved.anchorTime, const TimeOfDay(hour: 8, minute: 0));
      // First window in an empty patient lands at sortOrder 0.
      expect(saved.sortOrder, 0);
      // Popped back to the windows list.
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('a new window appends after existing ones (sortOrder grows)',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-morning', 'Morning', sortOrder: 0));
      await repo.upsertWindow(_window('w-evening', 'Evening',
          anchor: const TimeOfDay(hour: 18, minute: 0), sortOrder: 3));

      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(DoseWindowFormScreen.labelFieldKey), 'Bedtime');
      await tester.tap(find.byKey(DoseWindowFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final List<DoseWindow> windows = await repo.windowsForPatient(_patientId);
      final DoseWindow added =
          windows.firstWhere((DoseWindow w) => w.label == 'Bedtime');
      // max(existing sortOrder) + 1 == 3 + 1.
      expect(added.sortOrder, 4);
    });

    testWidgets('a lowercase name is capitalised on save '
        '(fb_1780933015339071)', (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(DoseWindowFormScreen.labelFieldKey), 'after lunch');
      await tester.tap(find.byKey(DoseWindowFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final DoseWindow saved =
          (await repo.windowsForPatient(_patientId)).single;
      // Each word title-cased on disk regardless of how it was typed.
      expect(saved.label, 'After Lunch');
    });
  });

  group('DoseWindowFormScreen — as-needed toggle', () {
    testWidgets('toggling "as needed" hides the time field and saves a null '
        'anchor', (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      // The time field shows by default.
      expect(find.byKey(DoseWindowFormScreen.timeFieldKey), findsOneWidget);

      await tester.tap(find.byKey(DoseWindowFormScreen.asNeededToggleKey));
      await tester.pumpAndSettle();

      // Time field is gone once the window is as-needed.
      expect(find.byKey(DoseWindowFormScreen.timeFieldKey), findsNothing);

      await tester.enterText(
          find.byKey(DoseWindowFormScreen.labelFieldKey), 'PRN pain');
      await tester.tap(find.byKey(DoseWindowFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final DoseWindow saved =
          (await repo.windowsForPatient(_patientId)).single;
      // Capitalised on save (each word title-cased), so "PRN pain" lands
      // as "PRN Pain".
      expect(saved.label, 'PRN Pain');
      expect(saved.anchorTime, isNull);
      expect(saved.isAsNeeded, isTrue);
    });
  });

  group('DoseWindowFormScreen — validation', () {
    testWidgets('an empty label is rejected and nothing persists',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.tap(find.byKey(DoseWindowFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('A label is required.'), findsOneWidget);
      expect(await repo.windowsForPatient(_patientId), isEmpty);
      expect(find.text('list-stub'), findsNothing); // still on the form
    });

    testWidgets('a label that duplicates another window is rejected',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-morning', 'Morning', sortOrder: 0));

      await _pumpForm(tester, repo: repo);

      // Same name (case-insensitive) as the existing window.
      await tester.enterText(
          find.byKey(DoseWindowFormScreen.labelFieldKey), 'morning');
      await tester.tap(find.byKey(DoseWindowFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Another window already uses that name.'),
          findsOneWidget);
      // No second window was written.
      expect(await repo.windowsForPatient(_patientId), hasLength(1));
    });
  });

  group('DoseWindowFormScreen — edit', () {
    testWidgets('hydrates the existing window, renames it, updates in place',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-9', 'Mornin', sortOrder: 2));

      await _pumpForm(tester, repo: repo, editId: 'w-9');

      // Hydrated label lands in the field.
      expect(find.text('Mornin'), findsOneWidget);

      await tester.enterText(
          find.byKey(DoseWindowFormScreen.labelFieldKey), 'Morning');
      await tester.tap(find.byKey(DoseWindowFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final List<DoseWindow> windows = await repo.windowsForPatient(_patientId);
      expect(windows, hasLength(1)); // same row, no duplicate
      final DoseWindow updated = windows.single;
      expect(updated.id, 'w-9');
      expect(updated.label, 'Morning');
      // sortOrder is preserved across an edit.
      expect(updated.sortOrder, 2);
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('editing keeps the same label when only that name exists '
        '(no false duplicate)', (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-9', 'Morning', sortOrder: 0));

      await _pumpForm(tester, repo: repo, editId: 'w-9');

      // Re-saving without changing the label must not trip the
      // duplicate-label validator against itself.
      await tester.tap(find.byKey(DoseWindowFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Another window already uses that name.'),
          findsNothing);
      expect(await repo.windowsForPatient(_patientId), hasLength(1));
      expect(find.text('list-stub'), findsOneWidget);
    });
  });

  group('DoseWindowFormScreen — delete', () {
    testWidgets('delete is edit-only, confirms, then removes the window',
        (WidgetTester tester) async {
      // Add path: no delete affordance.
      await _pumpForm(tester, repo: repo);
      expect(find.byKey(DoseWindowFormScreen.deleteButtonKey), findsNothing);

      // Edit path: delete confirms then removes the window.
      await repo.upsertWindow(_window('w-7', 'Noon', sortOrder: 1));
      await _pumpForm(tester, repo: repo, editId: 'w-7');
      expect(find.byKey(DoseWindowFormScreen.deleteButtonKey), findsOneWidget);

      await tester.tap(find.byKey(DoseWindowFormScreen.deleteButtonKey));
      await tester.pumpAndSettle();
      // Confirm dialog — empty window uses the plain "Delete" action.
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(await repo.windowsForPatient(_patientId), isEmpty);
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('cancelling the delete dialog keeps the window',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-7', 'Noon', sortOrder: 1));
      await _pumpForm(tester, repo: repo, editId: 'w-7');

      await tester.tap(find.byKey(DoseWindowFormScreen.deleteButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(await repo.windowsForPatient(_patientId), hasLength(1));
    });
  });
}

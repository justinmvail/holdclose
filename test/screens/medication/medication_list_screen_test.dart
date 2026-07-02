import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/link_launcher_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/medication/medication_list_screen.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Widget coverage for the medication list at `/medications` — empty
/// state + its CTA, populated rendering, tap-to-edit navigation, the add
/// FAB, and long-press soft-delete. Previously covered only by goldens.

const String _patientId = 'demo-patient-mary';

DateTime _fixedNow() => DateTime(2026, 6, 4, 9, 0);

Medication _med(
  String id,
  String name, {
  String dosage = '10 mg',
  MedicationRoute route = MedicationRoute.oral,
}) =>
    Medication(id: id, name: name, dosage: dosage, route: route);

DoseWindow _window(
  String id,
  String label, {
  TimeOfDay anchor = const TimeOfDay(hour: 8, minute: 0),
  int sortOrder = 0,
}) =>
    DoseWindow(
      id: id,
      patientId: _patientId,
      label: label,
      anchorTime: anchor,
      sortOrder: sortOrder,
    );

MedicationWindowEntry _entry(String id, String medId, String windowId) =>
    MedicationWindowEntry(
      id: id,
      medicationId: medId,
      windowId: windowId,
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 1, 1),
    );

/// Pumps the medication list at `/medications` plus the child routes its
/// rows / FAB push to, recording each navigation for assertions.
Future<({MedicationRepository repo, List<String> nav})> _pumpList(
  WidgetTester tester, {
  required MedicationRepository repo,
  List<Override> extraOverrides = const <Override>[],
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> nav = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();

  final GoRouter router = GoRouter(
    initialLocation: '/medications',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        parentNavigatorKey: rootKey,
        builder: (BuildContext c, GoRouterState s) =>
            const MedicationListScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) {
              nav.add('new');
              return const Scaffold(body: Center(child: Text('new-stub')));
            },
          ),
          GoRoute(
            path: 'windows',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) {
              nav.add('windows');
              return const Scaffold(
                  body: Center(child: Text('windows-stub')));
            },
          ),
          GoRoute(
            path: ':id/edit',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) {
              nav.add('edit:${s.pathParameters['id']}');
              return const Scaffold(body: Center(child: Text('edit-stub')));
            },
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        medicationListClockProvider.overrideWithValue(_fixedNow),
        // The list resolves its patient id via activePatientIdProvider →
        // storageProvider; an empty in-memory store keeps the test off
        // on-device sqlite and falls back to 'demo-patient-mary' (the
        // windows above are keyed on it), so behaviour is unchanged.
        storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
        ...extraOverrides,
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (repo: repo, nav: nav);
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

  group('MedicationListScreen — empty', () {
    testWidgets('renders the empty state with its add CTA, no FAB',
        (WidgetTester tester) async {
      await _pumpList(tester, repo: repo);

      expect(find.byKey(MedicationListScreen.emptyStateKey), findsOneWidget);
      expect(find.text('No medications yet.'), findsOneWidget);
      expect(find.byKey(MedicationListScreen.emptyCtaKey), findsOneWidget);
      // The FAB is suppressed while the list is empty.
      expect(find.byKey(MedicationListScreen.fabKey), findsNothing);
      expect(find.byKey(MedicationListScreen.listKey), findsNothing);
    });

    testWidgets('the empty-state CTA navigates to the new-medication route',
        (WidgetTester tester) async {
      final ({MedicationRepository repo, List<String> nav}) h =
          await _pumpList(tester, repo: repo);

      await tester.tap(find.byKey(MedicationListScreen.emptyCtaKey));
      await tester.pumpAndSettle();

      expect(h.nav, contains('new'));
      expect(find.text('new-stub'), findsOneWidget);
    });
  });

  group('MedicationListScreen — populated', () {
    Future<void> seedTwo() async {
      await repo.upsertWindow(_window('w-morning', 'Morning'));
      await repo.upsertMedication(_med('m-don', 'Donepezil', dosage: '10 mg'));
      await repo.upsertMedication(_med('m-ibu', 'Ibuprofen', dosage: '200 mg'));
      await repo.upsertEntry(_entry('e-don', 'm-don', 'w-morning'));
    }

    testWidgets('renders one card per medication with name + dosage',
        (WidgetTester tester) async {
      await seedTwo();
      await _pumpList(tester, repo: repo);

      expect(find.byKey(MedicationListScreen.listKey), findsOneWidget);
      expect(find.byKey(MedicationListScreen.emptyStateKey), findsNothing);

      expect(
          find.byKey(MedicationListScreen.tileKey('m-don')), findsOneWidget);
      expect(
          find.byKey(MedicationListScreen.tileKey('m-ibu')), findsOneWidget);

      expect(find.text('Donepezil'), findsOneWidget);
      expect(find.text('Ibuprofen'), findsOneWidget);
      expect(find.text('10 mg'), findsOneWidget);
      expect(find.text('200 mg'), findsOneWidget);

      // The medication with an entry shows its window; the other shows the
      // "no window yet" prompt.
      expect(find.text('No time window yet — tap to add one.'),
          findsOneWidget);
    });

    testWidgets('the add FAB shows and navigates to the new-medication route',
        (WidgetTester tester) async {
      await seedTwo();
      final ({MedicationRepository repo, List<String> nav}) h =
          await _pumpList(tester, repo: repo);

      expect(find.byKey(MedicationListScreen.fabKey), findsOneWidget);

      await tester.tap(find.byKey(MedicationListScreen.fabKey));
      await tester.pumpAndSettle();

      expect(h.nav, contains('new'));
      expect(find.text('new-stub'), findsOneWidget);
    });

    testWidgets('tapping a card navigates to that medication\'s edit route',
        (WidgetTester tester) async {
      await seedTwo();
      final ({MedicationRepository repo, List<String> nav}) h =
          await _pumpList(tester, repo: repo);

      await tester.tap(find.byKey(MedicationListScreen.tileKey('m-don')));
      await tester.pumpAndSettle();

      expect(h.nav, contains('edit:m-don'));
      expect(find.text('edit-stub'), findsOneWidget);
    });

    testWidgets('the "manage windows" header action opens the windows route',
        (WidgetTester tester) async {
      await seedTwo();
      final ({MedicationRepository repo, List<String> nav}) h =
          await _pumpList(tester, repo: repo);

      await tester.tap(find.byTooltip('Manage time windows'));
      await tester.pumpAndSettle();

      expect(h.nav, contains('windows'));
      expect(find.text('windows-stub'), findsOneWidget);
    });
  });

  group('MedicationListScreen — soft delete', () {
    testWidgets('long-press → confirm soft-deletes the med (drops it)',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med('m-ibu', 'Ibuprofen'));
      await _pumpList(tester, repo: repo);

      await tester.longPress(find.byKey(MedicationListScreen.tileKey('m-ibu')));
      await tester.pumpAndSettle();

      expect(
          find.byKey(MedicationListScreen.deleteDialogKey), findsOneWidget);
      await tester.tap(find.byKey(MedicationListScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      // Soft-deleted meds drop out of the live list.
      expect(await repo.listMedications(), isEmpty);
      // Still on the list screen, now showing the empty state.
      expect(find.byKey(MedicationListScreen.emptyStateKey), findsOneWidget);
    });

    testWidgets('the per-card trash icon also confirms + soft-deletes',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med('m-ibu', 'Ibuprofen'));
      await _pumpList(tester, repo: repo);

      await tester
          .tap(find.byKey(MedicationListScreen.deleteIconKey('m-ibu')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(MedicationListScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      expect(await repo.listMedications(), isEmpty);
    });

    testWidgets('cancelling the delete dialog keeps the med',
        (WidgetTester tester) async {
      await repo.upsertMedication(_med('m-ibu', 'Ibuprofen'));
      await _pumpList(tester, repo: repo);

      await tester.longPress(find.byKey(MedicationListScreen.tileKey('m-ibu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MedicationListScreen.deleteCancelKey));
      await tester.pumpAndSettle();

      expect(await repo.listMedications(), hasLength(1));
      expect(
          find.byKey(MedicationListScreen.tileKey('m-ibu')), findsOneWidget);
    });
  });

  group('MedicationListScreen — refill runway', () {
    testWidgets('shows a "No refills left" chip + Call, and dials the pharmacy',
        (WidgetTester tester) async {
      final RecordingLinkLauncher launcher = RecordingLinkLauncher();
      await repo.upsertWindow(_window('w-morning', 'Morning'));
      await repo.upsertMedication(const Medication(
        id: 'm-tiz',
        name: 'Tizanidine',
        dosage: '2 mg',
        route: MedicationRoute.oral,
        quantity: '180',
        refills: '0',
        pharmacyName: 'CVS Pharmacy',
        pharmacyPhone: '843-767-4500',
        dateFilled: '12/3/21',
      ));
      await repo.upsertEntry(_entry('e-tiz', 'm-tiz', 'w-morning'));

      await _pumpList(tester, repo: repo, extraOverrides: <Override>[
        linkLauncherProvider.overrideWithValue(launcher),
      ]);

      expect(
          find.byKey(MedicationListScreen.supplyKey('m-tiz')), findsOneWidget);
      expect(find.text('No refills left'), findsOneWidget);

      await tester
          .tap(find.byKey(MedicationListScreen.callPharmacyKey('m-tiz')));
      await tester.pumpAndSettle();

      expect(launcher.launched, hasLength(1));
      expect(launcher.launched.single, Uri(scheme: 'tel', path: '8437674500'));
    });

    testWidgets('no runway line for a med without label data',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-morning', 'Morning'));
      await repo.upsertMedication(_med('m-plain', 'Aspirin'));
      await repo.upsertEntry(_entry('e-plain', 'm-plain', 'w-morning'));

      await _pumpList(tester, repo: repo);

      expect(find.byKey(MedicationListScreen.supplyKey('m-plain')),
          findsNothing);
      expect(find.byKey(MedicationListScreen.callPharmacyKey('m-plain')),
          findsNothing);
    });
  });
}

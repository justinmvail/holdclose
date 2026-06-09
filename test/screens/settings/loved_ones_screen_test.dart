import 'package:careblazers/models/patient.dart';
import 'package:careblazers/providers/active_patient_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/settings/loved_ones_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Widget coverage for the "Loved ones" manager (Issue #6): it lists every
/// loved one with the active one flagged, switching the active person
/// updates the active-patient provider, and "Add a loved one" routes to
/// the setup screen.

Patient _patient(String id, String name) => Patient(
      id: id,
      name: name,
      age: 78,
      diagnosis: "Alzheimer's disease",
      diagnosedAt: DateTime.utc(2022, 1, 1),
      medications: const <CrisisMedication>[],
      allergies: const <String>[],
      calms: const <String>[],
      escalates: const <String>[],
      primaryCaregiver: const Contact(name: 'Sam', phone: '555'),
      healthcarePOA: const Contact(name: 'Sam', phone: '555'),
      advanceDirective:
          const AdvanceDirectiveStatus(onFileAt: 'Not on file', dnr: false),
    );

/// Pumps the manager at `/loved-ones` plus the `add` child route (a stub
/// recording the navigation) backed by [storage].
Future<({List<String> nav})> _pump(
  WidgetTester tester, {
  required InMemoryStorageProvider storage,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> nav = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/loved-ones',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/loved-ones',
        parentNavigatorKey: rootKey,
        builder: (BuildContext c, GoRouterState s) => const LovedOnesScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'add',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) {
              nav.add('add');
              return const Scaffold(body: Center(child: Text('add-stub')));
            },
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (nav: nav);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lists every loved one with the active one flagged',
      (WidgetTester tester) async {
    final InMemoryStorageProvider storage = InMemoryStorageProvider();
    addTearDown(storage.dispose);
    await storage.upsertPatient(_patient('p-mary', 'Mary Henderson'));
    await storage.upsertPatient(_patient('p-frank', 'Frank Albright'));
    await storage.setActivePatientId('p-mary');

    await _pump(tester, storage: storage);

    expect(find.byKey(LovedOnesScreen.listKey), findsOneWidget);
    expect(find.byKey(LovedOnesScreen.rowKey('p-mary')), findsOneWidget);
    expect(find.byKey(LovedOnesScreen.rowKey('p-frank')), findsOneWidget);
    // Mary is active → her row carries the Active badge; Frank's does not.
    expect(find.byKey(LovedOnesScreen.activeBadgeKey('p-mary')),
        findsOneWidget);
    expect(find.byKey(LovedOnesScreen.activeBadgeKey('p-frank')),
        findsNothing);
    expect(find.text('Mary Henderson'), findsOneWidget);
    expect(find.text('Frank Albright'), findsOneWidget);
  });

  testWidgets('tapping a non-active loved one switches the active patient',
      (WidgetTester tester) async {
    final InMemoryStorageProvider storage = InMemoryStorageProvider();
    addTearDown(storage.dispose);
    await storage.upsertPatient(_patient('p-mary', 'Mary Henderson'));
    await storage.upsertPatient(_patient('p-frank', 'Frank Albright'));
    await storage.setActivePatientId('p-mary');

    await _pump(tester, storage: storage);

    // Tap Frank's row.
    await tester.tap(find.byKey(LovedOnesScreen.rowKey('p-frank')));
    await tester.pumpAndSettle();

    // Storage now records Frank as active, and the badge moved to him.
    expect(await storage.getActivePatientId(), 'p-frank');
    expect(find.byKey(LovedOnesScreen.activeBadgeKey('p-frank')),
        findsOneWidget);
    expect(find.byKey(LovedOnesScreen.activeBadgeKey('p-mary')), findsNothing);
  });

  testWidgets('switching updates the activePatient provider', (tester) async {
    final InMemoryStorageProvider storage = InMemoryStorageProvider();
    addTearDown(storage.dispose);
    await storage.upsertPatient(_patient('p-mary', 'Mary Henderson'));
    await storage.upsertPatient(_patient('p-frank', 'Frank Albright'));
    await storage.setActivePatientId('p-mary');

    // Drive switchActivePatient through a real container so we can read the
    // active-patient provider before + after.
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(container.dispose);
    final ProviderSubscription<Object?> keepAlive =
        container.listen(activePatientProvider, (_, __) {});
    addTearDown(keepAlive.close);

    expect((await container.read(activePatientProvider.future))!.id, 'p-mary');

    // Use the screen's switch helper via a throwaway widget so it gets a
    // WidgetRef bound to the same container.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext c, WidgetRef ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => switchActivePatient(ref, 'p-frank'),
                child: const Text('switch'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();

    expect((await container.read(activePatientProvider.future))!.id,
        'p-frank');
  });

  testWidgets('"Add a loved one" routes to the setup screen',
      (WidgetTester tester) async {
    final InMemoryStorageProvider storage = InMemoryStorageProvider();
    addTearDown(storage.dispose);
    await storage.upsertPatient(_patient('p-mary', 'Mary Henderson'));

    final ({List<String> nav}) pumped = await _pump(tester, storage: storage);

    await tester.tap(find.byKey(LovedOnesScreen.addButtonKey));
    await tester.pumpAndSettle();

    expect(pumped.nav, contains('add'));
    expect(find.text('add-stub'), findsOneWidget);
  });

  testWidgets('renders an empty state with no loved ones',
      (WidgetTester tester) async {
    final InMemoryStorageProvider storage = InMemoryStorageProvider();
    addTearDown(storage.dispose);

    await _pump(tester, storage: storage);

    expect(find.byKey(LovedOnesScreen.emptyStateKey), findsOneWidget);
    // The Add CTA is always present.
    expect(find.byKey(LovedOnesScreen.addButtonKey), findsOneWidget);
  });
}

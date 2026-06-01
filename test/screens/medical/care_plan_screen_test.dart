import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_plan_section.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/screens/medical/care_plan_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

CarePlanSection _section({
  required String id,
  CarePlanSlot slot = CarePlanSlot.morning,
  String title = 'Routine',
  String body = 'Do the thing.',
  int order = 0,
  CareStage appliesInStage = CareStage.anyStage,
}) =>
    CarePlanSection(
      id: id,
      patientId: 'demo-patient-mary',
      slot: slot,
      title: title,
      body: body,
      order: order,
      appliesInStage: appliesInStage,
    );

Future<void> _pumpScreen(
  WidgetTester tester, {
  required CarePlanRepository repo,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/medical/care-plan',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('home'))),
      ),
      GoRoute(
        path: '/medical',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('medical'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'care-plan',
            builder: (BuildContext context, GoRouterState state) =>
                const CarePlanScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: 'new',
                builder: (BuildContext context, GoRouterState state) =>
                    const Scaffold(body: Center(child: Text('new-form'))),
              ),
              GoRoute(
                path: ':id/edit',
                builder: (BuildContext context, GoRouterState state) => Scaffold(
                  body:
                      Center(child: Text('edit-${state.pathParameters['id']}')),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        carePlanRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CareblazersDatabase db;
  late CarePlanRepository repo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = CarePlanRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  // ---- carePlanReorderedIds (pure helper) --------------------------------

  group('carePlanReorderedIds', () {
    test('moving an item down decrements the target index', () {
      expect(
        carePlanReorderedIds(<String>['a', 'b', 'c'], 0, 2),
        equals(<String>['b', 'a', 'c']),
      );
    });

    test('moving an item up keeps the target index', () {
      expect(
        carePlanReorderedIds(<String>['a', 'b', 'c'], 2, 0),
        equals(<String>['c', 'a', 'b']),
      );
    });
  });

  // ---- Empty state -------------------------------------------------------

  testWidgets('empty state shows the inline CTA, no FAB',
      (WidgetTester tester) async {
    await _pumpScreen(tester, repo: repo);

    expect(find.byKey(CarePlanScreen.emptyStateKey), findsOneWidget);
    expect(find.byKey(CarePlanScreen.emptyCtaKey), findsOneWidget);
    expect(find.byKey(CarePlanScreen.fabKey), findsNothing);
    // 'Care Plan' renders as both the terminal breadcrumb and the title.
    expect(find.text('Care Plan'), findsNWidgets(2));
  });

  testWidgets('empty CTA navigates to the new-section form',
      (WidgetTester tester) async {
    await _pumpScreen(tester, repo: repo);

    await tester.tap(find.byKey(CarePlanScreen.emptyCtaKey));
    await tester.pumpAndSettle();

    expect(find.text('new-form'), findsOneWidget);
  });

  // ---- Slot grouping -----------------------------------------------------

  testWidgets('groups visible sections by slot, in slot order',
      (WidgetTester tester) async {
    await repo.upsert(_section(
      id: 'm1',
      slot: CarePlanSlot.morning,
      title: 'Wake gently',
    ));
    await repo.upsert(_section(
      id: 'e1',
      slot: CarePlanSlot.evening,
      title: 'Dim the lights',
    ));
    await repo.upsert(_section(
      id: 'a1',
      slot: CarePlanSlot.asNeeded,
      title: 'If she refuses a bath',
    ));

    await _pumpScreen(tester, repo: repo);

    expect(find.byKey(CarePlanScreen.listKey), findsOneWidget);
    expect(find.byKey(CarePlanScreen.fabKey), findsOneWidget);

    // Only the populated slots render a header.
    expect(
        find.byKey(CarePlanScreen.slotHeaderKey(CarePlanSlot.morning)),
        findsOneWidget);
    expect(
        find.byKey(CarePlanScreen.slotHeaderKey(CarePlanSlot.evening)),
        findsOneWidget);
    expect(
        find.byKey(CarePlanScreen.slotHeaderKey(CarePlanSlot.asNeeded)),
        findsOneWidget);
    expect(
        find.byKey(CarePlanScreen.slotHeaderKey(CarePlanSlot.afternoon)),
        findsNothing);

    // Morning sits above Evening sits above As needed (slot order).
    final double morningY = tester
        .getTopLeft(find.byKey(CarePlanScreen.slotHeaderKey(CarePlanSlot.morning)))
        .dy;
    final double eveningY = tester
        .getTopLeft(find.byKey(CarePlanScreen.slotHeaderKey(CarePlanSlot.evening)))
        .dy;
    final double asNeededY = tester
        .getTopLeft(
            find.byKey(CarePlanScreen.slotHeaderKey(CarePlanSlot.asNeeded)))
        .dy;
    expect(morningY < eveningY, isTrue);
    expect(eveningY < asNeededY, isTrue);
  });

  // ---- Stage filter ------------------------------------------------------

  testWidgets('stage filter shows the stage plus any-stage, hides others',
      (WidgetTester tester) async {
    await repo.upsert(_section(
      id: 'early1',
      slot: CarePlanSlot.morning,
      appliesInStage: CareStage.early,
    ));
    await repo.upsert(_section(
      id: 'late1',
      slot: CarePlanSlot.morning,
      order: 1,
      appliesInStage: CareStage.late,
    ));
    await repo.upsert(_section(
      id: 'any1',
      slot: CarePlanSlot.morning,
      order: 2,
      appliesInStage: CareStage.anyStage,
    ));

    await _pumpScreen(tester, repo: repo);

    // All → every card visible.
    expect(find.byKey(CarePlanScreen.cardKey('early1')), findsOneWidget);
    expect(find.byKey(CarePlanScreen.cardKey('late1')), findsOneWidget);
    expect(find.byKey(CarePlanScreen.cardKey('any1')), findsOneWidget);

    // Switch to Late: the late + any-stage cards stay, the early one hides.
    await tester.tap(find.descendant(
      of: find.byKey(CarePlanScreen.segmentedKey),
      matching: find.text('Late'),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(CarePlanScreen.cardKey('early1')), findsNothing);
    expect(find.byKey(CarePlanScreen.cardKey('late1')), findsOneWidget);
    expect(find.byKey(CarePlanScreen.cardKey('any1')), findsOneWidget);
  });

  testWidgets('a stage with no matching sections shows the no-match view',
      (WidgetTester tester) async {
    await repo.upsert(_section(
      id: 'early1',
      slot: CarePlanSlot.morning,
      appliesInStage: CareStage.early,
    ));

    await _pumpScreen(tester, repo: repo);

    await tester.tap(find.descendant(
      of: find.byKey(CarePlanScreen.segmentedKey),
      matching: find.text('Late'),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(CarePlanScreen.noMatchKey), findsOneWidget);
    expect(find.byKey(CarePlanScreen.listKey), findsNothing);
  });

  // ---- Tap to edit -------------------------------------------------------

  testWidgets('tapping a card opens the edit form for that section',
      (WidgetTester tester) async {
    await repo.upsert(_section(id: 'm1', title: 'Wake gently'));

    await _pumpScreen(tester, repo: repo);
    await tester.tap(find.byKey(CarePlanScreen.cardKey('m1')));
    await tester.pumpAndSettle();

    expect(find.text('edit-m1'), findsOneWidget);
  });

  // ---- Reorder within a slot --------------------------------------------

  testWidgets('reordering a slot persists the new order through the notifier',
      (WidgetTester tester) async {
    await repo.upsert(_section(id: 'a', slot: CarePlanSlot.morning, order: 0));
    await repo.upsert(_section(id: 'b', slot: CarePlanSlot.morning, order: 1));
    await repo.upsert(_section(id: 'c', slot: CarePlanSlot.morning, order: 2));

    await _pumpScreen(tester, repo: repo);

    final ReorderableListView list = tester.widget<ReorderableListView>(
      find.byKey(CarePlanScreen.slotListKey(CarePlanSlot.morning)),
    );
    // Move 'a' (index 0) down to the index-2 slot → [b, a, c].
    list.onReorder(0, 2);
    await tester.pumpAndSettle();

    final List<CarePlanSection> morning =
        await repo.bySlot(CarePlanSlot.morning);
    expect(
      morning.map((CarePlanSection s) => s.id).toList(),
      equals(<String>['b', 'a', 'c']),
    );
    for (int i = 0; i < morning.length; i++) {
      expect(morning[i].order, equals(i));
    }
  });
}

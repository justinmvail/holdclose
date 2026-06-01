import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_plan_section.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medical/care_plan_section_form.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Deterministic id factory so a saved section's id is stable.
String Function() _counterFactory() {
  int n = 0;
  return () => 'cp-id${n++}';
}

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

Future<void> _pumpForm(
  WidgetTester tester, {
  required CarePlanRepository repo,
  String? editSectionId,
  String Function()? idFactory,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final String initialLocation = editSectionId == null
      ? '/medical/care-plan/new'
      : '/medical/care-plan/$editSectionId/edit';

  final GoRouter router = GoRouter(
    initialLocation: initialLocation,
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/care-plan',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('list-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                const CarePlanSectionForm(),
          ),
          GoRoute(
            path: ':id/edit',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                CarePlanSectionForm(sectionId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        carePlanRepositoryProvider.overrideWithValue(repo),
        storageProvider.overrideWithValue(InMemoryStorageProvider()),
        carePlanFormIdFactoryProvider
            .overrideWithValue(idFactory ?? _counterFactory()),
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

  testWidgets('add path renders the slot + stage pickers and an empty form',
      (WidgetTester tester) async {
    await _pumpForm(tester, repo: repo);

    expect(find.byKey(CarePlanSectionForm.formKey), findsOneWidget);
    expect(find.byKey(CarePlanSectionForm.titleFieldKey), findsOneWidget);
    expect(find.byKey(CarePlanSectionForm.bodyFieldKey), findsOneWidget);
    expect(find.byKey(CarePlanSectionForm.deleteButtonKey), findsNothing);
    // Every slot + stage has a chip.
    for (final CarePlanSlot slot in CarePlanSlot.values) {
      expect(find.byKey(CarePlanSectionForm.slotChipKey(slot)), findsOneWidget);
    }
    for (final CareStage stage in CareStage.values) {
      expect(
          find.byKey(CarePlanSectionForm.stageChipKey(stage)), findsOneWidget);
    }
  });

  testWidgets('save validates required title + body', (WidgetTester tester) async {
    await _pumpForm(tester, repo: repo);

    await tester.tap(find.byKey(CarePlanSectionForm.saveButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('Give this section a title.'), findsOneWidget);
    expect(find.text('Add a few words on what to do.'), findsOneWidget);
    // Nothing persisted.
    expect(await repo.listAll(), isEmpty);
  });

  testWidgets('add saves a new section with the chosen slot + stage',
      (WidgetTester tester) async {
    await _pumpForm(tester, repo: repo, idFactory: () => 'cp-fixed');

    await tester.enterText(
        find.byKey(CarePlanSectionForm.titleFieldKey), 'Wind down');
    await tester.enterText(
        find.byKey(CarePlanSectionForm.bodyFieldKey), '- Dim the lights');
    await tester.tap(find.byKey(CarePlanSectionForm.slotChipKey(
      CarePlanSlot.evening,
    )));
    await tester.tap(find.byKey(CarePlanSectionForm.stageChipKey(
      CareStage.middle,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(CarePlanSectionForm.saveButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('list-stub'), findsOneWidget);

    final CarePlanSection? saved = await repo.getById('cp-fixed');
    expect(saved, isNotNull);
    expect(saved!.title, equals('Wind down'));
    expect(saved.body, equals('- Dim the lights'));
    expect(saved.slot, equals(CarePlanSlot.evening));
    expect(saved.appliesInStage, equals(CareStage.middle));
    expect(saved.order, equals(0));
  });

  testWidgets('edit in place keeps slot + order and updates content',
      (WidgetTester tester) async {
    await repo.upsert(_section(id: 'a', slot: CarePlanSlot.morning, order: 0));
    await repo.upsert(_section(
      id: 'b',
      slot: CarePlanSlot.morning,
      order: 1,
      title: 'Before',
    ));

    await _pumpForm(tester, repo: repo, editSectionId: 'b');

    expect(find.byKey(CarePlanSectionForm.deleteButtonKey), findsOneWidget);

    await tester.enterText(
        find.byKey(CarePlanSectionForm.titleFieldKey), 'After');
    await tester.tap(find.byKey(CarePlanSectionForm.saveButtonKey));
    await tester.pumpAndSettle();

    final CarePlanSection? edited = await repo.getById('b');
    expect(edited!.title, equals('After'));
    expect(edited.slot, equals(CarePlanSlot.morning));
    expect(edited.order, equals(1));
  });

  testWidgets('changing slot on edit re-homes the section and compacts',
      (WidgetTester tester) async {
    await repo.upsert(_section(id: 'a', slot: CarePlanSlot.morning, order: 0));
    await repo.upsert(_section(id: 'b', slot: CarePlanSlot.morning, order: 1));
    await repo.upsert(_section(id: 'e', slot: CarePlanSlot.evening, order: 0));

    await _pumpForm(tester, repo: repo, editSectionId: 'a');

    await tester.tap(find.byKey(CarePlanSectionForm.slotChipKey(
      CarePlanSlot.evening,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CarePlanSectionForm.saveButtonKey));
    await tester.pumpAndSettle();

    // 'a' now lives in the evening slot, appended after 'e'.
    final CarePlanSection? moved = await repo.getById('a');
    expect(moved!.slot, equals(CarePlanSlot.evening));
    final List<CarePlanSection> evening =
        await repo.bySlot(CarePlanSlot.evening);
    expect(
      evening.map((CarePlanSection s) => s.id).toList(),
      equals(<String>['e', 'a']),
    );
    // The morning slot closed the gap 'a' left — 'b' renumbers to 0.
    final List<CarePlanSection> morning =
        await repo.bySlot(CarePlanSlot.morning);
    expect(morning.map((CarePlanSection s) => s.id).toList(),
        equals(<String>['b']));
    expect(morning.single.order, equals(0));
  });

  testWidgets('delete removes the section', (WidgetTester tester) async {
    await repo.upsert(_section(id: 'a', slot: CarePlanSlot.morning, order: 0));

    await _pumpForm(tester, repo: repo, editSectionId: 'a');
    await tester.tap(find.byKey(CarePlanSectionForm.deleteButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('list-stub'), findsOneWidget);
    expect(await repo.getById('a'), isNull);
  });
}

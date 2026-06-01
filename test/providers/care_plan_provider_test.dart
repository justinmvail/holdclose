import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_plan_section.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

CarePlanSection _section({
  required String id,
  String patientId = 'mary',
  CarePlanSlot slot = CarePlanSlot.morning,
  String title = 'Routine',
  String body = 'Do the thing.',
  int order = 0,
  CareStage appliesInStage = CareStage.anyStage,
}) =>
    CarePlanSection(
      id: id,
      patientId: patientId,
      slot: slot,
      title: title,
      body: body,
      order: order,
      appliesInStage: appliesInStage,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---- Repository CRUD via the in-memory ("fake") database --------------

  group('CarePlanRepository — Phase 14.18 (in-memory DB)', () {
    late CareblazersDatabase db;
    late CarePlanRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = CarePlanRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('upsert + getById round-trips the model through SQLite', () async {
      final CarePlanSection s = _section(
        id: 'cp-1',
        slot: CarePlanSlot.evening,
        title: 'Wind-down',
        body: '- Dim lights',
        order: 1,
        appliesInStage: CareStage.middle,
      );
      await repo.upsert(s);

      expect(await repo.getById('cp-1'), equals(s));
    });

    test('getById returns null for an unknown id', () async {
      expect(await repo.getById('never-existed'), isNull);
    });

    test('upsert replaces an existing row by id (update path)', () async {
      final CarePlanSection original = _section(id: 'cp-1', title: 'Before');
      await repo.upsert(original);

      final CarePlanSection edited = original.copyWith(title: 'After');
      await repo.upsert(edited);

      expect(await repo.getById('cp-1'), equals(edited));
      expect(await repo.listAll(), hasLength(1));
    });

    test('delete removes the row; no-op for a missing id', () async {
      await repo.upsert(_section(id: 'cp-1'));
      await repo.delete('cp-1');
      expect(await repo.getById('cp-1'), isNull);

      // Deleting again is harmless.
      await repo.delete('cp-1');
      expect(await repo.listAll(), isEmpty);
    });

    test('bySlot filters to one slot, ordered by order index', () async {
      await repo.upsert(
          _section(id: 'm2', slot: CarePlanSlot.morning, order: 1));
      await repo.upsert(
          _section(id: 'm1', slot: CarePlanSlot.morning, order: 0));
      await repo.upsert(
          _section(id: 'e1', slot: CarePlanSlot.evening, order: 0));

      final List<CarePlanSection> morning =
          await repo.bySlot(CarePlanSlot.morning);
      expect(morning.map((CarePlanSection s) => s.id).toList(),
          <String>['m1', 'm2']);
      expect(await repo.bySlot(CarePlanSlot.night), isEmpty);
    });
  });

  // ---- Notifier: CRUD + selectors + ordering integrity ------------------

  group('CarePlan notifier — Phase 14.18', () {
    late CareblazersDatabase db;

    ProviderContainer makeContainer() {
      db = CareblazersDatabase(NativeDatabase.memory());
      final CarePlanRepository repo = CarePlanRepository(db);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          carePlanRepositoryProvider.overrideWithValue(repo),
        ],
      );
      // Keep the notifier subscription alive for the test's duration.
      container.listen<AsyncValue<List<CarePlanSection>>>(
        carePlanProvider,
        (AsyncValue<List<CarePlanSection>>? _,
            AsyncValue<List<CarePlanSection>> __) {},
        fireImmediately: true,
      );
      return container;
    }

    tearDown(() async {
      await db.close();
    });

    test('build starts empty, then add/updateSection/delete persist',
        () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      expect(await container.read(carePlanProvider.future), isEmpty);

      final CarePlan notifier = container.read(carePlanProvider.notifier);
      await notifier.add(_section(id: 'cp-1', title: 'Morning meds'));
      expect(container.read(carePlanProvider).requireValue.single.title,
          'Morning meds');

      // updateSection edits content in place; pass back the section with
      // its assigned order (0 — the first add of its slot).
      await notifier.updateSection(
          _section(id: 'cp-1', title: 'Morning meds + water', order: 0));
      expect(container.read(carePlanProvider).requireValue.single.title,
          'Morning meds + water');

      await notifier.delete('cp-1');
      expect(container.read(carePlanProvider).requireValue, isEmpty);
    });

    test('add assigns contiguous 0-based orders per slot', () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final CarePlan notifier = container.read(carePlanProvider.notifier);
      // All three adds pass order: 0 — the notifier must override each so
      // the slot ends up 0,1,2 with no duplicates.
      await notifier.add(_section(id: 'a', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'b', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'c', slot: CarePlanSlot.morning));

      final List<CarePlanSection> morning =
          notifier.bySlot(CarePlanSlot.morning);
      expect(morning.map((CarePlanSection s) => s.id).toList(),
          <String>['a', 'b', 'c']);
      expect(morning.map((CarePlanSection s) => s.order).toList(),
          <int>[0, 1, 2]);
    });

    test('orders are independent per slot', () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final CarePlan notifier = container.read(carePlanProvider.notifier);
      await notifier.add(_section(id: 'm1', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'e1', slot: CarePlanSlot.evening));
      await notifier.add(_section(id: 'm2', slot: CarePlanSlot.morning));

      expect(notifier.bySlot(CarePlanSlot.morning).map((s) => s.order),
          <int>[0, 1]);
      expect(notifier.bySlot(CarePlanSlot.evening).single.order, 0);
    });

    test('bySlot selector reads off the loaded list', () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final CarePlan notifier = container.read(carePlanProvider.notifier);
      await notifier.add(_section(id: 'm1', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'n1', slot: CarePlanSlot.night));

      expect(notifier.bySlot(CarePlanSlot.morning).map((s) => s.id),
          <String>['m1']);
      expect(notifier.bySlot(CarePlanSlot.night).map((s) => s.id),
          <String>['n1']);
      expect(notifier.bySlot(CarePlanSlot.afternoon), isEmpty);
    });

    test('reorder reassigns the slot to a contiguous, duplicate-free run',
        () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final CarePlan notifier = container.read(carePlanProvider.notifier);
      await notifier.add(_section(id: 'a', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'b', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'c', slot: CarePlanSlot.morning));

      // Move 'c' to the front.
      await notifier
          .reorder(CarePlanSlot.morning, <String>['c', 'a', 'b']);

      final List<CarePlanSection> morning =
          notifier.bySlot(CarePlanSlot.morning);
      expect(morning.map((CarePlanSection s) => s.id).toList(),
          <String>['c', 'a', 'b']);
      expect(morning.map((CarePlanSection s) => s.order).toList(),
          <int>[0, 1, 2]);
      // No duplicate order ints.
      final List<int> orders =
          morning.map((CarePlanSection s) => s.order).toList();
      expect(orders.toSet(), hasLength(orders.length));
    });

    test('delete closes the gap by renumbering the slot survivors',
        () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final CarePlan notifier = container.read(carePlanProvider.notifier);
      await notifier.add(_section(id: 'a', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'b', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'c', slot: CarePlanSlot.morning));

      // Remove the middle one — 'a'=0, 'c'=2 would leave a gap at 1.
      await notifier.delete('b');

      final List<CarePlanSection> morning =
          notifier.bySlot(CarePlanSlot.morning);
      expect(morning.map((CarePlanSection s) => s.id).toList(),
          <String>['a', 'c']);
      // Gap closed: contiguous 0,1 — not 0,2.
      expect(morning.map((CarePlanSection s) => s.order).toList(),
          <int>[0, 1]);
    });

    test('deleting from one slot leaves other slots untouched', () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final CarePlan notifier = container.read(carePlanProvider.notifier);
      await notifier.add(_section(id: 'm1', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'm2', slot: CarePlanSlot.morning));
      await notifier.add(_section(id: 'e1', slot: CarePlanSlot.evening));

      await notifier.delete('m1');

      expect(notifier.bySlot(CarePlanSlot.morning).map((s) => s.id),
          <String>['m2']);
      expect(notifier.bySlot(CarePlanSlot.morning).single.order, 0);
      // Evening slot is unaffected.
      expect(notifier.bySlot(CarePlanSlot.evening).single.id, 'e1');
      expect(notifier.bySlot(CarePlanSlot.evening).single.order, 0);
    });
  });
}

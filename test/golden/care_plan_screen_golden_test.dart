import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_plan_section.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/screens/medical/care_plan_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

CarePlanRepository _emptyRepo() =>
    CarePlanRepository(CareblazersDatabase(NativeDatabase.memory()));

Future<CarePlanRepository> _populatedRepo() async {
  final CarePlanRepository repo =
      CarePlanRepository(CareblazersDatabase(NativeDatabase.memory()));

  CarePlanSection s({
    required String id,
    required CarePlanSlot slot,
    required String title,
    required String body,
    required int order,
    required CareStage appliesInStage,
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

  await repo.upsert(s(
    id: 'm1',
    slot: CarePlanSlot.morning,
    title: 'Wash-up routine',
    body: '## Steps\n'
        '- Run a **warm** bath, never hot\n'
        '- Lay clothes out in the order they go on',
    order: 0,
    appliesInStage: CareStage.middle,
  ));
  await repo.upsert(s(
    id: 'm2',
    slot: CarePlanSlot.morning,
    title: 'Breakfast',
    body: 'Offer two simple choices. Keep the table _uncluttered_.',
    order: 1,
    appliesInStage: CareStage.anyStage,
  ));
  await repo.upsert(s(
    id: 'e1',
    slot: CarePlanSlot.evening,
    title: 'Sundowning wind-down',
    body: '- Dim the lights an hour before bed\n'
        '- Put on the music she knows',
    order: 0,
    appliesInStage: CareStage.late,
  ));
  await repo.upsert(s(
    id: 'a1',
    slot: CarePlanSlot.asNeeded,
    title: 'If she refuses a bath',
    body: 'Step away, try again after lunch. Do not push in the moment.',
    order: 0,
    appliesInStage: CareStage.anyStage,
  ));
  return repo;
}

Widget _host(CarePlanRepository repo) {
  final GoRouter router = GoRouter(
    initialLocation: '/medical/care-plan',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/care-plan',
        builder: (BuildContext context, GoRouterState state) =>
            const CarePlanScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      carePlanRepositoryProvider.overrideWithValue(repo),
    ],
    child: SizedBox(
      width: 420,
      height: 1000,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('CarePlanScreen golden', () {
    goldenTest(
      'empty care plan',
      fileName: 'care_plan_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 14.19)',
            child: _host(_emptyRepo()),
          ),
        ],
      ),
    );

    goldenTest(
      'populated care plan — grouped by slot',
      fileName: 'care_plan_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 14.19)',
            child: FutureBuilder<CarePlanRepository>(
              future: _populatedRepo(),
              builder: (BuildContext context,
                  AsyncSnapshot<CarePlanRepository> snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                return _host(snap.data!);
              },
            ),
          ),
        ],
      ),
    );
  });
}

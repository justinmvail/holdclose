import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/health_log_entry.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/screens/medical/health_log_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Fixed local "now" so "Today"/"Yesterday" + relative-time labels are
/// deterministic regardless of the host timezone.
DateTime _fixedNow() => DateTime(2026, 6, 1, 12);

HealthLogEntry _entry({
  required String id,
  required DateTime recordedAt,
  HealthLogKind kind = HealthLogKind.note,
  int? severity,
  int? systolic,
  int? diastolic,
  int? heartRate,
  double? temperatureF,
  int? glucoseMgDl,
  String? notes,
}) =>
    HealthLogEntry(
      id: id,
      patientId: 'demo-patient-mary',
      recordedAt: recordedAt,
      kind: kind,
      severity: severity,
      systolic: systolic,
      diastolic: diastolic,
      heartRate: heartRate,
      temperatureF: temperatureF,
      glucoseMgDl: glucoseMgDl,
      notes: notes,
    );

Future<void> _pumpScreen(
  WidgetTester tester, {
  required HealthLogRepository repo,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/medical/health-log',
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
            path: 'health-log',
            builder: (BuildContext context, GoRouterState state) =>
                const HealthLogScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: 'new',
                builder: (BuildContext context, GoRouterState state) =>
                    const Scaffold(body: Center(child: Text('new-form'))),
              ),
              GoRoute(
                path: ':id/edit',
                builder: (BuildContext context, GoRouterState state) => Scaffold(
                  body: Center(
                      child: Text('edit-${state.pathParameters['id']}')),
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
        healthLogRepositoryProvider.overrideWithValue(repo),
        healthLogClockProvider.overrideWithValue(_fixedNow),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HoldcloseDatabase db;
  late HealthLogRepository repo;

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
    repo = HealthLogRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('empty state shows the inline CTA, no FAB',
      (WidgetTester tester) async {
    await _pumpScreen(tester, repo: repo);

    expect(find.byKey(HealthLogScreen.emptyStateKey), findsOneWidget);
    expect(find.byKey(HealthLogScreen.emptyCtaKey), findsOneWidget);
    expect(find.byKey(HealthLogScreen.fabKey), findsNothing);
    // 'Health Log' renders as both the terminal breadcrumb and the title.
    expect(find.text('Health Log'), findsNWidgets(2));
  });

  testWidgets('empty CTA navigates to the new-entry form',
      (WidgetTester tester) async {
    await _pumpScreen(tester, repo: repo);

    await tester.tap(find.byKey(HealthLogScreen.emptyCtaKey));
    await tester.pumpAndSettle();

    expect(find.text('new-form'), findsOneWidget);
  });

  testWidgets('populated list groups by day and renders kind summaries',
      (WidgetTester tester) async {
    await repo.upsert(_entry(
      id: 'v1',
      kind: HealthLogKind.vitals,
      recordedAt: DateTime(2026, 6, 1, 10),
      systolic: 130,
      diastolic: 82,
      heartRate: 76,
    ));
    await repo.upsert(_entry(
      id: 's1',
      kind: HealthLogKind.symptom,
      recordedAt: DateTime(2026, 5, 31, 15),
      severity: 3,
      notes: 'Headache',
    ));
    await repo.upsert(_entry(
      id: 'n1',
      kind: HealthLogKind.note,
      recordedAt: DateTime(2026, 5, 31, 9),
      notes: 'Slept well and ate a full breakfast.',
    ));

    await _pumpScreen(tester, repo: repo);

    expect(find.byKey(HealthLogScreen.listKey), findsOneWidget);
    expect(find.byKey(HealthLogScreen.fabKey), findsOneWidget);

    // Day headers: today + yesterday.
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);

    // One-line summaries per kind.
    expect(find.text('BP 130/82 · HR 76'), findsOneWidget);
    expect(find.text('Headache · 3/5'), findsOneWidget);
    expect(find.text('Slept well and ate a full breakfast.'), findsOneWidget);

    // Every row is present and keyed by id.
    expect(find.byKey(HealthLogScreen.rowKey('v1')), findsOneWidget);
    expect(find.byKey(HealthLogScreen.rowKey('s1')), findsOneWidget);
    expect(find.byKey(HealthLogScreen.rowKey('n1')), findsOneWidget);
  });

  testWidgets('a vitals row summary includes the blood glucose reading',
      (WidgetTester tester) async {
    await repo.upsert(_entry(
      id: 'g1',
      kind: HealthLogKind.vitals,
      recordedAt: DateTime(2026, 6, 1, 8),
      heartRate: 72,
      glucoseMgDl: 110,
    ));

    await _pumpScreen(tester, repo: repo);

    expect(find.text('HR 72 · 110 mg/dL'), findsOneWidget);
  });

  testWidgets('tapping a row opens the edit form for that entry',
      (WidgetTester tester) async {
    await repo.upsert(_entry(
      id: 'v1',
      kind: HealthLogKind.vitals,
      recordedAt: DateTime(2026, 6, 1, 10),
      systolic: 130,
      diastolic: 82,
    ));

    await _pumpScreen(tester, repo: repo);
    await tester.tap(find.byKey(HealthLogScreen.rowKey('v1')));
    await tester.pumpAndSettle();

    expect(find.text('edit-v1'), findsOneWidget);
  });
}

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/health_log_entry.dart';
import 'package:careblazers/providers/health_log_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medical/health_log_entry_form.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 6, 1, 9, 30);

/// Deterministic id factory so a saved entry's id is stable.
String Function() _counterFactory() {
  int n = 0;
  return () => 'hl-id${n++}';
}

HealthLogEntry _entry({
  required String id,
  DateTime? recordedAt,
  HealthLogKind kind = HealthLogKind.vitals,
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
      recordedAt: recordedAt ?? DateTime(2026, 6, 1, 8),
      kind: kind,
      severity: severity,
      systolic: systolic,
      diastolic: diastolic,
      heartRate: heartRate,
      temperatureF: temperatureF,
      glucoseMgDl: glucoseMgDl,
      notes: notes,
    );

Future<({HealthLogRepository repo, List<String> nav})> _pumpForm(
  WidgetTester tester, {
  required HealthLogRepository repo,
  String? editEntryId,
  String Function()? idFactory,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> nav = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final String initialLocation = editEntryId == null
      ? '/medical/health-log/new'
      : '/medical/health-log/$editEntryId/edit';

  final GoRouter router = GoRouter(
    initialLocation: initialLocation,
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/health-log',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) {
          nav.add('list');
          return const Scaffold(body: Center(child: Text('list-stub')));
        },
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                const HealthLogEntryForm(),
          ),
          GoRoute(
            path: ':id/edit',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                HealthLogEntryForm(entryId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        healthLogRepositoryProvider.overrideWithValue(repo),
        storageProvider.overrideWithValue(InMemoryStorageProvider()),
        healthLogClockProvider.overrideWithValue(_fixedNow),
        healthLogFormIdFactoryProvider
            .overrideWithValue(idFactory ?? _counterFactory()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (repo: repo, nav: nav);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CareblazersDatabase db;
  late HealthLogRepository repo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = HealthLogRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('HealthLogEntryForm — conditional fields', () {
    testWidgets('defaults to vitals: vitals fields shown, severity hidden',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      expect(find.byKey(HealthLogEntryForm.vitalsSectionKey), findsOneWidget);
      expect(find.byKey(HealthLogEntryForm.systolicFieldKey), findsOneWidget);
      expect(find.byKey(HealthLogEntryForm.diastolicFieldKey), findsOneWidget);
      expect(find.byKey(HealthLogEntryForm.heartRateFieldKey), findsOneWidget);
      expect(
          find.byKey(HealthLogEntryForm.temperatureFieldKey), findsOneWidget);
      expect(find.byKey(HealthLogEntryForm.glucoseFieldKey), findsOneWidget);
      expect(find.byKey(HealthLogEntryForm.severitySectionKey), findsNothing);
      // Notes is always present.
      expect(find.byKey(HealthLogEntryForm.notesFieldKey), findsOneWidget);
    });

    testWidgets('symptom kind shows severity chips, hides vitals',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester
          .tap(find.byKey(HealthLogEntryForm.kindChipKey(HealthLogKind.symptom)));
      await tester.pumpAndSettle();

      expect(find.byKey(HealthLogEntryForm.vitalsSectionKey), findsNothing);
      expect(find.byKey(HealthLogEntryForm.systolicFieldKey), findsNothing);
      expect(find.byKey(HealthLogEntryForm.severitySectionKey), findsOneWidget);
      for (int level = 1; level <= 5; level++) {
        expect(find.byKey(HealthLogEntryForm.severityChipKey(level)),
            findsOneWidget);
      }
      expect(find.byKey(HealthLogEntryForm.notesFieldKey), findsOneWidget);
    });

    testWidgets('note kind hides both vitals and severity',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester
          .tap(find.byKey(HealthLogEntryForm.kindChipKey(HealthLogKind.note)));
      await tester.pumpAndSettle();

      expect(find.byKey(HealthLogEntryForm.vitalsSectionKey), findsNothing);
      expect(find.byKey(HealthLogEntryForm.severitySectionKey), findsNothing);
      expect(find.byKey(HealthLogEntryForm.notesFieldKey), findsOneWidget);
    });
  });

  group('HealthLogEntryForm — validation', () {
    testWidgets('vitals with no readings shows the cross-field error',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(HealthLogEntryForm.formErrorKey), findsOneWidget);
      // Nothing persisted, still on the form.
      expect(await repo.listAll(), isEmpty);
      expect(find.text('list-stub'), findsNothing);
    });

    testWidgets('a half-entered blood pressure is rejected',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(HealthLogEntryForm.systolicFieldKey), '130');
      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(HealthLogEntryForm.formErrorKey), findsOneWidget);
      expect(await repo.listAll(), isEmpty);
    });

    testWidgets('an out-of-range systolic value is rejected inline',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(HealthLogEntryForm.systolicFieldKey), '999');
      await tester.enterText(
          find.byKey(HealthLogEntryForm.diastolicFieldKey), '82');
      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Enter a systolic between 40 and 300.'), findsOneWidget);
      expect(await repo.listAll(), isEmpty);
    });

    testWidgets('symptom with empty notes is rejected inline',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester
          .tap(find.byKey(HealthLogEntryForm.kindChipKey(HealthLogKind.symptom)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Describe the symptom you noticed.'), findsOneWidget);
      expect(await repo.listAll(), isEmpty);
    });
  });

  group('HealthLogEntryForm — save + edit + delete', () {
    testWidgets('saving a vitals entry persists it and pops to the list',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, idFactory: _counterFactory());

      await tester.enterText(
          find.byKey(HealthLogEntryForm.systolicFieldKey), '130');
      await tester.enterText(
          find.byKey(HealthLogEntryForm.diastolicFieldKey), '82');
      await tester.enterText(
          find.byKey(HealthLogEntryForm.heartRateFieldKey), '76');
      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();

      final List<HealthLogEntry> all = await repo.listAll();
      expect(all, hasLength(1));
      final HealthLogEntry saved = all.single;
      expect(saved.kind, HealthLogKind.vitals);
      expect(saved.systolic, 130);
      expect(saved.diastolic, 82);
      expect(saved.heartRate, 76);
      expect(saved.recordedAt, _fixedNow());
      // Popped back to the list stub.
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('a blood-glucose-only vitals entry persists the reading',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo, idFactory: _counterFactory());

      await tester.enterText(
          find.byKey(HealthLogEntryForm.glucoseFieldKey), '110');
      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();

      final HealthLogEntry saved = (await repo.listAll()).single;
      expect(saved.kind, HealthLogKind.vitals);
      expect(saved.glucoseMgDl, 110);
      // No other reading was entered.
      expect(saved.systolic, isNull);
      expect(saved.heartRate, isNull);
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('an out-of-range blood glucose value is rejected inline',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
          find.byKey(HealthLogEntryForm.glucoseFieldKey), '999');
      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Enter a blood glucose between 20 and 600.'),
          findsOneWidget);
      expect(await repo.listAll(), isEmpty);
    });

    testWidgets('edit path hydrates a stored blood glucose reading',
        (WidgetTester tester) async {
      await repo.upsert(_entry(
        id: 'hl-g',
        kind: HealthLogKind.vitals,
        glucoseMgDl: 145,
      ));

      await _pumpForm(tester, repo: repo, editEntryId: 'hl-g');

      expect(find.text('145'), findsOneWidget);
    });

    testWidgets('saving a symptom entry stores severity + notes',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester
          .tap(find.byKey(HealthLogEntryForm.kindChipKey(HealthLogKind.symptom)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HealthLogEntryForm.severityChipKey(3)));
      await tester.enterText(
          find.byKey(HealthLogEntryForm.notesFieldKey), 'Headache');
      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();

      final HealthLogEntry saved = (await repo.listAll()).single;
      expect(saved.kind, HealthLogKind.symptom);
      expect(saved.severity, 3);
      expect(saved.notes, 'Headache');
      // Vitals fields are dropped for a non-vitals kind.
      expect(saved.systolic, isNull);
    });

    testWidgets('edit path hydrates fields and a save updates the row',
        (WidgetTester tester) async {
      await repo.upsert(_entry(
        id: 'hl-1',
        kind: HealthLogKind.vitals,
        systolic: 120,
        diastolic: 80,
        heartRate: 70,
        notes: 'Resting',
      ));

      await _pumpForm(tester, repo: repo, editEntryId: 'hl-1');

      // Hydrated values land in the controllers.
      expect(find.text('120'), findsOneWidget);
      expect(find.text('80'), findsOneWidget);
      expect(find.text('Resting'), findsOneWidget);

      await tester.enterText(
          find.byKey(HealthLogEntryForm.heartRateFieldKey), '88');
      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();

      final HealthLogEntry updated = (await repo.getById('hl-1'))!;
      expect(updated.heartRate, 88);
      // Same id, no duplicate row.
      expect(await repo.listAll(), hasLength(1));
    });

    testWidgets('delete action is edit-only and removes the row',
        (WidgetTester tester) async {
      // Add path: no delete button.
      await _pumpForm(tester, repo: repo);
      expect(find.byKey(HealthLogEntryForm.deleteButtonKey), findsNothing);

      // Edit path: delete removes the entry and pops.
      await repo.upsert(_entry(id: 'hl-9', kind: HealthLogKind.note,
          notes: 'A note'));
      await _pumpForm(tester, repo: repo, editEntryId: 'hl-9');
      expect(find.byKey(HealthLogEntryForm.deleteButtonKey), findsOneWidget);

      await tester.tap(find.byKey(HealthLogEntryForm.deleteButtonKey));
      await tester.pumpAndSettle();

      expect(await repo.getById('hl-9'), isNull);
      expect(find.text('list-stub'), findsOneWidget);
    });
  });

  group('HealthLogEntryForm — PathHeader back affordance', () {
    // Regression for alpha bug fb_1780932762335231: the breadcrumb back
    // affordance must be present on every branch — including before the
    // hydration future resolves — so the screen is never swipe-only.
    testWidgets('renders the PathHeader breadcrumb on the loading branch',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final GoRouter router = GoRouter(
        initialLocation: '/medical/health-log/new',
        routes: <RouteBase>[
          GoRoute(
            path: '/medical/health-log/new',
            builder: (BuildContext context, GoRouterState state) =>
                const HealthLogEntryForm(),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            healthLogRepositoryProvider.overrideWithValue(repo),
            storageProvider.overrideWithValue(InMemoryStorageProvider()),
            healthLogClockProvider.overrideWithValue(_fixedNow),
            healthLogFormIdFactoryProvider
                .overrideWithValue(_counterFactory()),
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
      expect(find.text('Health Log'), findsOneWidget);
    });
  });
}

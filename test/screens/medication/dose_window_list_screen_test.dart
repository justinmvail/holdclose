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

/// Widget coverage for the dose-window management list at
/// `/medications/windows` — empty state, populated rendering, tap-to-edit
/// navigation, and the per-row delete affordance. Previously covered only
/// by goldens. Drives the real screen against an in-memory repo.

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

/// Pumps the windows list at `/medications/windows` plus the child routes
/// the rows push to, recording each navigation so a tap can be asserted.
Future<({MedicationRepository repo, List<String> nav})> _pumpList(
  WidgetTester tester, {
  required MedicationRepository repo,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> nav = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();

  final GoRouter router = GoRouter(
    initialLocation: '/medications/windows',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medications/windows',
        parentNavigatorKey: rootKey,
        builder: (BuildContext c, GoRouterState s) =>
            const DoseWindowListScreen(),
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
            path: ':id',
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
        // The list now resolves its patient id via activePatientIdProvider
        // → storageProvider; an empty in-memory store keeps the test off
        // the on-device sqlite file and falls back to 'demo-patient-mary'
        // (the windows above are keyed on it), so behaviour is unchanged.
        storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
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
  late MedicationRepository repo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = MedicationRepository(db, clock: _fixedNow);
  });

  tearDown(() async {
    await db.close();
  });

  group('DoseWindowListScreen — empty', () {
    testWidgets('renders the empty state when no windows exist',
        (WidgetTester tester) async {
      await _pumpList(tester, repo: repo);

      expect(
          find.byKey(DoseWindowListScreen.emptyStateKey), findsOneWidget);
      expect(find.text('No time windows yet.'), findsOneWidget);
      // No list when empty.
      expect(find.byKey(DoseWindowListScreen.listKey), findsNothing);
      // The Add FAB is always present.
      expect(find.byKey(DoseWindowListScreen.fabKey), findsOneWidget);
    });
  });

  group('DoseWindowListScreen — populated', () {
    testWidgets('renders one row per window with labels + anchor times',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-morning', 'Morning',
          anchor: const TimeOfDay(hour: 8, minute: 0), sortOrder: 0));
      await repo.upsertWindow(_window('w-bedtime', 'Bedtime',
          anchor: const TimeOfDay(hour: 21, minute: 0), sortOrder: 1));
      await repo.upsertWindow(
          _window('w-prn', 'As needed', anchor: null, sortOrder: 2));

      await _pumpList(tester, repo: repo);

      expect(find.byKey(DoseWindowListScreen.listKey), findsOneWidget);
      expect(find.byKey(DoseWindowListScreen.emptyStateKey), findsNothing);

      expect(find.byKey(DoseWindowListScreen.tileKey('w-morning')),
          findsOneWidget);
      expect(find.byKey(DoseWindowListScreen.tileKey('w-bedtime')),
          findsOneWidget);
      expect(find.byKey(DoseWindowListScreen.tileKey('w-prn')),
          findsOneWidget);

      // Labels + the as-needed subtitle render.
      expect(find.text('Morning'), findsOneWidget);
      expect(find.text('Bedtime'), findsOneWidget);
      expect(find.text('As needed'), findsWidgets);
    });

    testWidgets('tapping a row navigates to that window\'s edit route',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-morning', 'Morning', sortOrder: 0));

      final ({MedicationRepository repo, List<String> nav}) h =
          await _pumpList(tester, repo: repo);

      await tester.tap(find.byKey(DoseWindowListScreen.tileKey('w-morning')));
      await tester.pumpAndSettle();

      expect(h.nav, contains('edit:w-morning'));
      expect(find.text('edit-stub'), findsOneWidget);
    });

    testWidgets('the FAB navigates to the new-window route',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-morning', 'Morning', sortOrder: 0));

      final ({MedicationRepository repo, List<String> nav}) h =
          await _pumpList(tester, repo: repo);

      await tester.tap(find.byKey(DoseWindowListScreen.fabKey));
      await tester.pumpAndSettle();

      expect(h.nav, contains('new'));
      expect(find.text('new-stub'), findsOneWidget);
    });
  });

  group('DoseWindowListScreen — delete affordance', () {
    testWidgets('each row exposes a delete button that confirms + removes',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-morning', 'Morning', sortOrder: 0));

      await _pumpList(tester, repo: repo);

      // The per-row trash icon is reachable via its tooltip.
      final Finder deleteButton = find.byTooltip('Delete time window');
      expect(deleteButton, findsOneWidget);

      await tester.tap(deleteButton);
      await tester.pumpAndSettle();

      // Confirm dialog for an unattached window uses the plain "Delete".
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(await repo.windowsForPatient(_patientId), isEmpty);
      // List collapses back to the empty state after the only row is gone.
      expect(find.byKey(DoseWindowListScreen.emptyStateKey), findsOneWidget);
    });

    testWidgets('cancelling the row delete keeps the window',
        (WidgetTester tester) async {
      await repo.upsertWindow(_window('w-morning', 'Morning', sortOrder: 0));

      await _pumpList(tester, repo: repo);

      await tester.tap(find.byTooltip('Delete time window'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(await repo.windowsForPatient(_patientId), hasLength(1));
      expect(find.byKey(DoseWindowListScreen.tileKey('w-morning')),
          findsOneWidget);
    });
  });
}

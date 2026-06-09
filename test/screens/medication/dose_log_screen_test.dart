import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Widget coverage for the "Today's doses" checklist at
/// `/medications/today` — rendering today's scheduled doses, marking a
/// dose taken / late, and re-statusing a logged dose to skipped via the
/// bottom sheet. Asserts every mutation lands as a [DoseLog] in the repo.
/// Previously covered only by goldens.

const String _patientId = 'demo-patient-mary';

/// 9:00 AM on 2026-06-04 — "now" for the screen's clock. The morning
/// window (8:00) sits 60 min back (→ marking it records *late*); the noon
/// window (9:00) sits at "now" (→ marking it records *taken*).
DateTime _fixedNow() => DateTime(2026, 6, 4, 9, 0);

/// The two scheduled-dose instants the seed below expands to today.
DateTime get _morningDose => DateTime(2026, 6, 4, 8, 0);
DateTime get _noonDose => DateTime(2026, 6, 4, 9, 0);

Medication _med(String id, String name, {String dosage = '10 mg'}) =>
    Medication(id: id, name: name, dosage: dosage, route: MedicationRoute.oral);

DoseWindow _window(String id, String label, TimeOfDay anchor, int sortOrder) =>
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

/// Seeds two meds across a morning (8:00) and noon (9:00) window so
/// [MedicationRepository.dosesByDay] expands exactly two doses today.
Future<void> _seedTwoDoses(MedicationRepository repo) async {
  await repo.upsertWindow(
      _window('w-morning', 'Morning', const TimeOfDay(hour: 8, minute: 0), 0));
  await repo.upsertWindow(
      _window('w-noon', 'Noon', const TimeOfDay(hour: 9, minute: 0), 1));
  await repo.upsertMedication(_med('m-don', 'Donepezil', dosage: '10 mg'));
  await repo.upsertMedication(_med('m-ibu', 'Ibuprofen', dosage: '200 mg'));
  await repo.upsertEntry(_entry('e-don', 'm-don', 'w-morning'));
  await repo.upsertEntry(_entry('e-ibu', 'm-ibu', 'w-noon'));
}

/// Monotonic id factory so logged doses get stable ids.
String Function() _counterFactory() {
  int n = 0;
  return () => 'log-id${n++}';
}

Future<MedicationRepository> _pumpScreen(
  WidgetTester tester, {
  required MedicationRepository repo,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/medications/today',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        parentNavigatorKey: rootKey,
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('list-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'today',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) => const DoseLogScreen(),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        doseLogClockProvider.overrideWithValue(_fixedNow),
        doseLogIdFactoryProvider.overrideWithValue(_counterFactory()),
        // dosesTodayProvider now resolves its patient id via
        // activePatientIdProvider → storageProvider; an empty in-memory
        // store keeps the test off the on-device sqlite file and falls back
        // to 'demo-patient-mary' (the windows above are keyed on it), so the
        // queried day is unchanged.
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

  group('DoseLogScreen — rendering', () {
    testWidgets('shows the empty state when nothing is scheduled today',
        (WidgetTester tester) async {
      await _pumpScreen(tester, repo: repo);

      expect(find.byKey(DoseLogScreen.emptyStateKey), findsOneWidget);
      expect(find.text('Nothing scheduled today.'), findsOneWidget);
      expect(find.byKey(DoseLogScreen.listKey), findsNothing);
    });

    testWidgets('renders today\'s scheduled doses grouped by window',
        (WidgetTester tester) async {
      await _seedTwoDoses(repo);
      await _pumpScreen(tester, repo: repo);

      expect(find.byKey(DoseLogScreen.listKey), findsOneWidget);

      // One row per scheduled dose, keyed by (medId, scheduledFor).
      expect(find.byKey(DoseLogScreen.rowKey('m-don', _morningDose)),
          findsOneWidget);
      expect(find.byKey(DoseLogScreen.rowKey('m-ibu', _noonDose)),
          findsOneWidget);

      // A window section header per window.
      expect(find.byKey(DoseLogScreen.windowHeaderKey('w-morning')),
          findsOneWidget);
      expect(find.byKey(DoseLogScreen.windowHeaderKey('w-noon')),
          findsOneWidget);

      expect(find.text('Donepezil'), findsOneWidget);
      expect(find.text('Ibuprofen'), findsOneWidget);

      // Both doses are unlogged → both offer a "Mark taken" CTA.
      expect(find.byKey(DoseLogScreen.markTakenButtonKey('m-don', _morningDose)),
          findsOneWidget);
      expect(find.byKey(DoseLogScreen.markTakenButtonKey('m-ibu', _noonDose)),
          findsOneWidget);
    });
  });

  group('DoseLogScreen — marking taken', () {
    testWidgets('marking the on-time (noon) dose persists a taken DoseLog',
        (WidgetTester tester) async {
      await _seedTwoDoses(repo);
      await _pumpScreen(tester, repo: repo);

      await tester.tap(
          find.byKey(DoseLogScreen.markTakenButtonKey('m-ibu', _noonDose)));
      await tester.pumpAndSettle();

      final List<DoseLog> logs = await repo.logsFor('m-ibu');
      expect(logs, hasLength(1));
      final DoseLog saved = logs.single;
      expect(saved.medicationId, 'm-ibu');
      expect(saved.scheduledFor, _noonDose);
      // 9:00 dose marked at 9:00 → within the 30-min window → "taken".
      expect(saved.status, DoseStatus.taken);
      expect(saved.takenAt, _fixedNow());

      // The row flips out of the unlogged state — no more "Mark taken".
      expect(find.byKey(DoseLogScreen.markTakenButtonKey('m-ibu', _noonDose)),
          findsNothing);
    });

    testWidgets('marking the overdue (morning) dose records it late + badges',
        (WidgetTester tester) async {
      await _seedTwoDoses(repo);
      await _pumpScreen(tester, repo: repo);

      // Tapping the row body (not just the button) also marks it.
      await tester
          .tap(find.byKey(DoseLogScreen.rowKey('m-don', _morningDose)));
      await tester.pumpAndSettle();

      final DoseLog saved = (await repo.logsFor('m-don')).single;
      expect(saved.scheduledFor, _morningDose);
      // 8:00 dose marked at 9:00 → 60 min late (> 30) → "late".
      expect(saved.status, DoseStatus.late);

      // The late badge renders for the now-logged-late row.
      expect(find.byKey(DoseLogScreen.lateBadgeKey('m-don', _morningDose)),
          findsOneWidget);
    });
  });

  group('DoseLogScreen — re-statusing a logged dose', () {
    testWidgets('tapping a logged dose opens the sheet; picking skipped '
        'persists DoseStatus.skipped', (WidgetTester tester) async {
      await _seedTwoDoses(repo);
      // Pre-log the noon dose as taken so the row is in the "logged" state.
      await repo.upsertDoseLog(DoseLog(
        id: 'log-seed',
        medicationId: 'm-ibu',
        scheduledFor: _noonDose,
        takenAt: _fixedNow(),
        status: DoseStatus.taken,
      ));

      await _pumpScreen(tester, repo: repo);

      // Logged rows have no "Mark taken" button; tapping opens the sheet.
      expect(find.byKey(DoseLogScreen.markTakenButtonKey('m-ibu', _noonDose)),
          findsNothing);

      await tester.tap(find.byKey(DoseLogScreen.rowKey('m-ibu', _noonDose)));
      await tester.pumpAndSettle();

      // The status sheet exposes one option per DoseStatus value.
      expect(find.byKey(DoseLogScreen.statusSheetOptionKey(DoseStatus.skipped)),
          findsOneWidget);

      await tester.tap(
          find.byKey(DoseLogScreen.statusSheetOptionKey(DoseStatus.skipped)));
      await tester.pumpAndSettle();

      // The same log row is updated in place (id preserved, status flipped).
      final List<DoseLog> logs = await repo.logsFor('m-ibu');
      expect(logs, hasLength(1));
      expect(logs.single.id, 'log-seed');
      expect(logs.single.status, DoseStatus.skipped);
      // skipped clears the taken stamp.
      expect(logs.single.takenAt, isNull);
    });
  });

  group('DoseLogScreen — bulk morning', () {
    testWidgets('"mark morning taken" logs every pending before-noon dose',
        (WidgetTester tester) async {
      await _seedTwoDoses(repo);
      await _pumpScreen(tester, repo: repo);

      // Both seeded doses are before noon (8:00, 9:00) and pending.
      expect(find.byKey(DoseLogScreen.bulkMorningButtonKey), findsOneWidget);

      await tester.tap(find.byKey(DoseLogScreen.bulkMorningButtonKey));
      await tester.pumpAndSettle();

      // Each med now carries a single log for its scheduled instant.
      final DoseLog morning = (await repo.logsFor('m-don')).single;
      final DoseLog noon = (await repo.logsFor('m-ibu')).single;
      expect(morning.status, DoseStatus.late); // 8:00 marked at 9:00
      expect(noon.status, DoseStatus.taken); // 9:00 marked at 9:00

      // Nothing left pending → the bulk button retreats.
      expect(find.byKey(DoseLogScreen.bulkMorningButtonKey), findsNothing);
    });
  });
}

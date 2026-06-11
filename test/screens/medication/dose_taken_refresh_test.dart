import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/patient_timeline_provider.dart'
    show patientDoseEventsProvider;
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Regression guard for the reported bug: "I marked evening medication as
/// taken but the home page didn't update."
///
/// The fix is `_markTaken` calling `invalidatePatientTimeline(ref)` (which
/// invalidates `patientDoseEventsProvider` — the dose source the Home
/// schedule card reads). This test drives the real Dose Log screen and
/// asserts the timeline provider flips the dose from *scheduled* to
/// *logged* after the tap — i.e. Home would refresh. If the invalidation
/// regresses, the timeline stays stale and this fails.

const String _patientId = 'demo-patient-mary';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CareblazersDatabase db;
  late MedicationRepository repo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = MedicationRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('marking a dose taken refreshes the patient timeline (Home)',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Pin BOTH the screen and the timeline provider to a FIXED clock via
    // doseLogClockProvider. patientDoseEventsProvider now reads that same
    // seam (2026-06-11), so the dose it projects for "today" and the dose
    // the screen shows agree deterministically — a run crossing midnight
    // can no longer change which day "today" resolves to mid-test.
    final DateTime now = DateTime(2026, 6, 11, 9, 30);
    final DateTime today8 = DateTime(now.year, now.month, now.day, 8, 0);

    // A daily 8am dose for one med.
    await repo.upsertWindow(const DoseWindow(
      id: 'w-am',
      patientId: _patientId,
      label: 'Morning',
      anchorTime: TimeOfDay(hour: 8, minute: 0),
      sortOrder: 0,
    ));
    await repo.upsertMedication(const Medication(
      id: 'm-don',
      name: 'Donepezil',
      dosage: '10 mg',
      route: MedicationRoute.oral,
    ));
    await repo.upsertEntry(MedicationWindowEntry(
      id: 'e-don',
      medicationId: 'm-don',
      windowId: 'w-am',
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 1, 1),
    ));

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        doseLogClockProvider.overrideWithValue(() => now),
        doseLogIdFactoryProvider.overrideWithValue(() => 'log-1'),
        // patientDoseEventsProvider now resolves its patient id via
        // activePatientIdProvider → storageProvider; an empty in-memory
        // store keeps the test off on-device sqlite and falls back to
        // 'demo-patient-mary' (the window above is keyed on it).
        storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
      ],
    );
    addTearDown(container.dispose);

    // BEFORE: the timeline carries today's 8am dose, still unlogged.
    final List<CareEvent> before =
        await container.read(patientDoseEventsProvider.future);
    final CareEvent doseBefore =
        before.firstWhere((CareEvent e) => e.windowSlot == today8);
    expect(doseBefore.kind, CareEventKind.doseScheduled);

    // Drive the real Dose Log screen in the SAME container.
    final GoRouter router = GoRouter(
      initialLocation: '/medications/today',
      routes: <RouteBase>[
        GoRoute(
          path: '/medications',
          builder: (BuildContext c, GoRouterState s) =>
              const Scaffold(body: SizedBox.shrink()),
          routes: <RouteBase>[
            GoRoute(
              path: 'today',
              builder: (BuildContext c, GoRouterState s) =>
                  const DoseLogScreen(),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
        find.byKey(DoseLogScreen.markTakenButtonKey('m-don', today8)));
    await tester.pumpAndSettle();

    // AFTER: the timeline re-read shows the dose logged — Home reflects it.
    final List<CareEvent> after =
        await container.read(patientDoseEventsProvider.future);
    final CareEvent doseAfter =
        after.firstWhere((CareEvent e) => e.windowSlot == today8);
    expect(doseAfter.kind, CareEventKind.doseLogged);
  });
}

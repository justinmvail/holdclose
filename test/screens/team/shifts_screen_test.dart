import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/care_shift.dart';
import 'package:holdclose/models/caregiver.dart';
import 'package:holdclose/models/patient.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/team/shifts_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';
final DateTime _clock = DateTime(2026, 6, 1, 12);

/// Minimal valid [Patient] for seeding the multi-patient active-id test.
/// Only `id` + `name` matter here (the screen reads the resolved id; the
/// in-memory store orders the no-active-id fallback by name).
Patient _patient(String id, String name) => Patient(
      id: id,
      name: name,
      age: 80,
      diagnosis: 'Alzheimer\'s',
      diagnosedAt: DateTime(2024, 1, 1),
      medications: const <CrisisMedication>[],
      allergies: const <String>[],
      calms: const <String>[],
      escalates: const <String>[],
      primaryCaregiver: const Contact(name: 'Sarah', phone: '555-0100'),
      healthcarePOA: const Contact(name: 'Sarah', phone: '555-0100'),
      advanceDirective: const AdvanceDirectiveStatus(
        onFileAt: 'Home binder',
        dnr: false,
      ),
    );

CareShift _onDay1({
  required String id,
  required String caregiverId,
  required int fromHour,
  required int toHour,
}) =>
    CareShift(
      id: id,
      caregiverId: caregiverId,
      start: DateTime(2026, 6, 1, fromHour),
      end: DateTime(2026, 6, 1, toHour),
      patientId: _patientId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HoldcloseDatabase db;
  late CareShiftsRepository shiftsRepo;
  late CareCircleRepository circleRepo;
  int ids = 0;

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
    shiftsRepo = CareShiftsRepository(db);
    circleRepo = CareCircleRepository(db);
    ids = 0;
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pump(WidgetTester tester, {StorageProvider? storage}) async {
    await tester.binding.setSurfaceSize(const Size(460, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          careShiftsRepositoryProvider.overrideWithValue(shiftsRepo),
          careCircleRepositoryProvider.overrideWithValue(circleRepo),
          careShiftsClockProvider.overrideWithValue(() => _clock),
          shiftIdFactoryProvider.overrideWithValue(() => 'new-${ids++}'),
          // Creating a shift now resolves the active loved one via
          // activePatientIdProvider → storageProvider; an empty in-memory
          // store keeps the test off the on-device sqlite file and falls
          // back to 'demo-patient-mary' (== _patientId), so the stamped
          // patientId is unchanged. Tests that need a specific active
          // patient pass a pre-seeded store.
          storageBackendProvider
              .overrideWithValue(storage ?? InMemoryStorageProvider()),
        ],
        child: const MaterialApp(home: ShiftsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ShiftsScreen — 7-day strip', () {
    testWidgets('renders seven day rows starting today', (tester) async {
      await pump(tester);

      for (int i = 0; i < 7; i++) {
        expect(find.byKey(ShiftsScreen.dayRowKey(i)), findsOneWidget);
      }
      expect(find.byKey(ShiftsScreen.dayRowKey(7)), findsNothing);
      // The lead day is labeled "Today".
      expect(find.textContaining('Today'), findsOneWidget);
    });

    testWidgets('an uncovered day captions the gap span', (tester) async {
      await shiftsRepo.upsertShift(
          _onDay1(id: 's1', caregiverId: 'c1', fromHour: 8, toHour: 18));
      await pump(tester);

      // Today (day 0): covered 8am–6pm, so two gaps remain.
      final Text caption =
          tester.widget<Text>(find.byKey(ShiftsScreen.captionKey(0)));
      expect(caption.data, contains('uncovered'));
      expect(caption.data, contains('12am–8am'));
      expect(caption.data, contains('6pm–12am'));
    });

    testWidgets('a fully-covered day captions "fully covered"', (tester) async {
      await shiftsRepo.upsertShift(
          _onDay1(id: 'a', caregiverId: 'c1', fromHour: 0, toHour: 12));
      await shiftsRepo.upsertShift(
          _onDay1(id: 'b', caregiverId: 'c2', fromHour: 12, toHour: 24));
      await pump(tester);

      final Text caption =
          tester.widget<Text>(find.byKey(ShiftsScreen.captionKey(0)));
      expect(caption.data, '2 caregivers · fully covered');
    });

    testWidgets('a day with no shifts captions "No coverage scheduled"',
        (tester) async {
      await pump(tester);
      final Text caption =
          tester.widget<Text>(find.byKey(ShiftsScreen.captionKey(3)));
      expect(caption.data, 'No coverage scheduled');
    });
  });

  group('ShiftsScreen — schedule sheet', () {
    testWidgets('FAB opens the schedule sheet', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ShiftsScreen.fabKey));
      await tester.pumpAndSettle();
      expect(find.byKey(ShiftsScreen.scheduleSheetKey), findsOneWidget);
    });

    testWidgets('saving without a caregiver shows an error and adds nothing',
        (tester) async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await pump(tester);

      await tester.tap(find.byKey(ShiftsScreen.fabKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ShiftsScreen.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(ShiftsScreen.caregiverErrorKey), findsOneWidget);
      expect(await shiftsRepo.listShifts(), isEmpty);
    });

    testWidgets('picking a caregiver and saving creates a shift',
        (tester) async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await pump(tester);

      await tester.tap(find.byKey(ShiftsScreen.fabKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ShiftsScreen.caregiverOptionKey('c1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ShiftsScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // Sheet closed and the shift landed with the default 9am–5pm window.
      expect(find.byKey(ShiftsScreen.scheduleSheetKey), findsNothing);
      final List<CareShift> shifts = await shiftsRepo.listShifts();
      expect(shifts.single.caregiverId, 'c1');
      expect(shifts.single.start, DateTime(2026, 6, 1, 9));
      expect(shifts.single.end, DateTime(2026, 6, 1, 17));
      // The default (single-patient) active id is stamped on the new shift.
      expect(shifts.single.patientId, _patientId);
    });

    testWidgets(
        'a new shift is stamped with the ACTIVE loved one (multi-patient)',
        (tester) async {
      // Two loved ones on file with the second selected as active. The new
      // shift must follow that selection rather than the demo fallback,
      // proving activePatientIdProvider is threaded into the write path.
      const String activeId = 'patient-bob';
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      await storage.upsertPatient(_patient('demo-patient-mary', 'Mary'));
      await storage.upsertPatient(_patient(activeId, 'Bob'));
      await storage.setActivePatientId(activeId);

      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await pump(tester, storage: storage);

      await tester.tap(find.byKey(ShiftsScreen.fabKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ShiftsScreen.caregiverOptionKey('c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ShiftsScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final List<CareShift> shifts = await shiftsRepo.listShifts();
      expect(shifts.single.patientId, activeId);
    });

    testWidgets('the picker prompts when the circle is empty', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ShiftsScreen.fabKey));
      await tester.pumpAndSettle();
      expect(
        find.text('Add caregivers to your Care Circle first.'),
        findsOneWidget,
      );
    });

    testWidgets('the start picker accepts a date + time and updates the button',
        (tester) async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await pump(tester);

      await tester.tap(find.byKey(ShiftsScreen.fabKey));
      await tester.pumpAndSettle();

      // Open the start picker, accept the default date, then the default
      // time — exercising the date+time flow without dragging the dial.
      await tester.tap(find.byKey(ShiftsScreen.startButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Back on the sheet with the start unchanged (default 9:00 AM).
      expect(find.byKey(ShiftsScreen.scheduleSheetKey), findsOneWidget);
      expect(find.text('Jun 1, 9:00 AM'), findsOneWidget);
    });
  });

  group('ShiftsScreen — edit + delete a band', () {
    testWidgets('tapping a band opens the sheet prefilled with a Remove action',
        (tester) async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await shiftsRepo.upsertShift(
          _onDay1(id: 's1', caregiverId: 'c1', fromHour: 8, toHour: 18));
      await pump(tester);

      await tester.tap(find.byKey(ShiftsScreen.bandKey('s1')));
      await tester.pumpAndSettle();

      // The schedule sheet opened in edit mode: the band's caregiver is
      // preselected and the Remove action is offered.
      expect(find.byKey(ShiftsScreen.scheduleSheetKey), findsOneWidget);
      expect(find.text('Edit shift'), findsOneWidget);
      expect(find.byKey(ShiftsScreen.deleteButtonKey), findsOneWidget);
      // Seeded start/end show on the time buttons (8am–6pm on day 1).
      expect(find.text('Jun 1, 8:00 AM'), findsOneWidget);
      expect(find.text('Jun 1, 6:00 PM'), findsOneWidget);
    });

    testWidgets('removing a band deletes the shift and persists the removal',
        (tester) async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await shiftsRepo.upsertShift(
          _onDay1(id: 's1', caregiverId: 'c1', fromHour: 8, toHour: 18));
      await pump(tester);

      await tester.tap(find.byKey(ShiftsScreen.bandKey('s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ShiftsScreen.deleteButtonKey));
      await tester.pumpAndSettle();

      // Confirm dialog appears; confirm the removal.
      expect(find.byKey(ShiftsScreen.deleteDialogKey), findsOneWidget);
      await tester.tap(find.byKey(ShiftsScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      // Gone from the strip and from the in-memory repo.
      expect(find.byKey(ShiftsScreen.bandKey('s1')), findsNothing);
      expect(await shiftsRepo.listShifts(), isEmpty);
    });

    testWidgets('cancelling the removal keeps the shift', (tester) async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await shiftsRepo.upsertShift(
          _onDay1(id: 's1', caregiverId: 'c1', fromHour: 8, toHour: 18));
      await pump(tester);

      await tester.tap(find.byKey(ShiftsScreen.bandKey('s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ShiftsScreen.deleteButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ShiftsScreen.deleteCancelKey));
      await tester.pumpAndSettle();

      // Still on disk after a cancelled removal.
      expect((await shiftsRepo.listShifts()).single.id, 's1');
    });

    testWidgets('editing a band updates it in place — same id, no duplicate',
        (tester) async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c2',
        displayName: 'James Park',
        role: CaregiverRole.child,
      ));
      await shiftsRepo.upsertShift(
          _onDay1(id: 's1', caregiverId: 'c1', fromHour: 8, toHour: 18));
      await pump(tester);

      await tester.tap(find.byKey(ShiftsScreen.bandKey('s1')));
      await tester.pumpAndSettle();

      // Reassign the shift to a different caregiver, then save.
      await tester.tap(find.byKey(ShiftsScreen.caregiverOptionKey('c2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ShiftsScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // Exactly one shift, same id, new caregiver, unchanged window.
      final List<CareShift> shifts = await shiftsRepo.listShifts();
      expect(shifts, hasLength(1));
      expect(shifts.single.id, 's1');
      expect(shifts.single.caregiverId, 'c2');
      expect(shifts.single.start, DateTime(2026, 6, 1, 8));
      expect(shifts.single.end, DateTime(2026, 6, 1, 18));
    });
  });
}

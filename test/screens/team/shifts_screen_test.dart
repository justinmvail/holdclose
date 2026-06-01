import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_shift.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/care_shifts_provider.dart';
import 'package:careblazers/screens/team/shifts_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';
final DateTime _clock = DateTime(2026, 6, 1, 12);

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

  late CareblazersDatabase db;
  late CareShiftsRepository shiftsRepo;
  late CareCircleRepository circleRepo;
  int ids = 0;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    shiftsRepo = CareShiftsRepository(db);
    circleRepo = CareCircleRepository(db);
    ids = 0;
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(460, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          careShiftsRepositoryProvider.overrideWithValue(shiftsRepo),
          careCircleRepositoryProvider.overrideWithValue(circleRepo),
          careShiftsClockProvider.overrideWithValue(() => _clock),
          shiftIdFactoryProvider.overrideWithValue(() => 'new-${ids++}'),
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
}

import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart';
import 'package:holdclose/models/care_event.dart';
import 'package:holdclose/providers/home_clock_provider.dart';
import 'package:holdclose/providers/patient_timeline_provider.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/home/schedule_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
// hide Provider — clashes with the care-model Provider used to seed the
// appointment's FK below.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Widget coverage for the Home Schedule card's window grouping. Overrides
/// the merged timeline provider directly with canned dose events so the
/// test is deterministic (no DB, no health-log dependency) and proves the
/// window-name + anchor-time header — including that a dose logged off its
/// anchor still reads under its window's time, not the logged time.

const String _patient = 'demo-patient-mary';

CareEvent _dose({
  required String id,
  required String med,
  required DateTime start,
  required DateTime slot,
  required String window,
  required bool taken,
}) =>
    CareEvent(
      id: id,
      kind: taken ? CareEventKind.doseLogged : CareEventKind.doseScheduled,
      title: med,
      start: start,
      patientId: _patient,
      windowLabel: window,
      windowSlot: slot,
    );

Future<void> _pumpCard(
  WidgetTester tester,
  List<CareEvent> events,
  DateTime now,
) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        homeClockProvider.overrideWithValue(() => now),
        patientTimelineEventsProvider.overrideWith(
          (Ref ref) async => events,
        ),
      ],
      child: MaterialApp(
        theme: holdcloseLightTheme,
        home: const Scaffold(
          body: SingleChildScrollView(child: ScheduleCard()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'heads each today dose group with the window name + anchor time, '
    'listing every med due then',
    (WidgetTester tester) async {
      final DateTime now = DateTime(2026, 6, 1, 16); // 4pm today
      final DateTime morningSlot = DateTime(2026, 6, 1, 8); // 8am anchor
      final DateTime eveningSlot = DateTime(2026, 6, 1, 18); // 6pm anchor

      final List<CareEvent> events = <CareEvent>[
        // Morning window: both given, but logged at 2:15pm (off-anchor).
        _dose(
          id: 'd1',
          med: 'Ibuprofen',
          start: DateTime(2026, 6, 1, 14, 15),
          slot: morningSlot,
          window: 'Morning',
          taken: true,
        ),
        _dose(
          id: 'd2',
          med: 'Tylenol',
          start: DateTime(2026, 6, 1, 14, 15),
          slot: morningSlot,
          window: 'Morning',
          taken: true,
        ),
        // Evening window: still scheduled.
        _dose(
          id: 'd3',
          med: 'Ibuprofen',
          start: eveningSlot,
          slot: eveningSlot,
          window: 'Evening',
          taken: false,
        ),
        _dose(
          id: 'd4',
          med: 'Tylenol',
          start: eveningSlot,
          slot: eveningSlot,
          window: 'Evening',
          taken: false,
        ),
      ];

      await _pumpCard(tester, events, now);

      // Today section renders.
      expect(find.byKey(ScheduleCard.todaySectionKey), findsOneWidget);

      // Each window heads its group by name, with "Medication" appended
      // so the slot reads unambiguously as meds in the mixed schedule...
      expect(find.textContaining('Morning Medication'), findsOneWidget);
      expect(find.textContaining('Evening Medication'), findsOneWidget);

      // ...with the window's ANCHOR time, not the 2:15pm logged time.
      expect(find.textContaining('8:00 AM'), findsOneWidget);
      expect(find.textContaining('6:00 PM'), findsOneWidget);
      expect(find.textContaining('2:15'), findsNothing);

      // Every med due in a window lists under it — one per window, so two
      // "Ibuprofen" rows and two "Tylenol" rows across Morning + Evening.
      expect(find.text('Ibuprofen'), findsNWidgets(2));
      expect(find.text('Tylenol'), findsNWidgets(2));
    },
  );

  testWidgets(
    "today's window group taps through to the dose log; tomorrow's does not",
    (WidgetTester tester) async {
      final DateTime now = DateTime(2026, 6, 1, 16);
      final List<CareEvent> events = <CareEvent>[
        _dose(
          id: 't1',
          med: 'TodayMed',
          start: DateTime(2026, 6, 1, 8),
          slot: DateTime(2026, 6, 1, 8),
          window: 'Morning',
          taken: false,
        ),
        _dose(
          id: 'm1',
          med: 'TomorrowMed',
          start: DateTime(2026, 6, 2, 8),
          slot: DateTime(2026, 6, 2, 8),
          window: 'Morning',
          taken: false,
        ),
      ];

      await _pumpCard(tester, events, now);

      final InkWell todayGroup = tester.widget<InkWell>(
        find.ancestor(
          of: find.text('TodayMed'),
          matching: find.byType(InkWell),
        ),
      );
      final InkWell tomorrowGroup = tester.widget<InkWell>(
        find.ancestor(
          of: find.text('TomorrowMed'),
          matching: find.byType(InkWell),
        ),
      );

      // Today routes to the (today-scoped) dose log; tomorrow has no
      // matching destination, so its tap is disabled.
      expect(todayGroup.onTap, isNotNull);
      expect(tomorrowGroup.onTap, isNull);
    },
  );

  testWidgets(
    "a tomorrow window keeps every med — the row cap counts windows, not "
    'doses, so a busy window is never sliced mid-list',
    (WidgetTester tester) async {
      // Regression: six meds due tomorrow morning. The old per-event cap
      // (4 tomorrow) truncated raw doses before grouping, so the 5th/6th
      // med vanished from the window even though the day had it.
      final DateTime now = DateTime(2026, 6, 1, 16);
      final DateTime slot = DateTime(2026, 6, 2, 8); // tomorrow 8am
      const List<String> meds = <String>[
        'Aspirin',
        'Donepezil',
        'Ibuprofen',
        'Metformin',
        'Simvastatin',
        'Tylenol',
      ];
      final List<CareEvent> events = <CareEvent>[
        for (int i = 0; i < meds.length; i++)
          _dose(
            id: 'd$i',
            med: meds[i],
            start: slot,
            slot: slot,
            window: 'Morning',
            taken: false,
          ),
      ];

      await _pumpCard(tester, events, now);

      expect(find.byKey(ScheduleCard.tomorrowSectionKey), findsOneWidget);
      // Every med renders under the one Morning window — including Tylenol,
      // which the old cap dropped.
      for (final String m in meds) {
        expect(find.text(m), findsOneWidget, reason: '$m should be listed');
      }
      // One window = one row → no overflow link.
      expect(find.byKey(ScheduleCard.moreRowKey), findsNothing);
    },
  );

  testWidgets(
    'rows past the cap roll into a "+N more" link rather than vanishing',
    (WidgetTester tester) async {
      // Seven distinct windows today → six fit, the seventh overflows.
      final DateTime now = DateTime(2026, 6, 1, 16);
      final List<CareEvent> events = <CareEvent>[
        for (final int h in <int>[6, 8, 10, 12, 14, 16, 18])
          _dose(
            id: 'w$h',
            med: 'Med$h',
            start: DateTime(2026, 6, 1, h),
            slot: DateTime(2026, 6, 1, h),
            window: 'Window $h',
            taken: false,
          ),
      ];

      await _pumpCard(tester, events, now);

      expect(find.byKey(ScheduleCard.moreRowKey), findsOneWidget);
      expect(find.text('+1 more in Calendar'), findsOneWidget);
    },
  );

  testWidgets(
    'day-divider band is the wider, higher-contrast bar (alpha '
    'fb_1780960026009050)',
    (WidgetTester tester) async {
      final DateTime now = DateTime(2026, 6, 1, 16);
      final List<CareEvent> events = <CareEvent>[
        _dose(
          id: 'd1',
          med: 'Ibuprofen',
          start: DateTime(2026, 6, 1, 18),
          slot: DateTime(2026, 6, 1, 18),
          window: 'Evening',
          taken: false,
        ),
      ];

      await _pumpCard(tester, events, now);

      // The Today header still renders...
      expect(find.byKey(ScheduleCard.todaySectionKey), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);

      // ...inside the widened band: the Container wrapping the "Today"
      // label carries the bumped padding (8px vertical / 12px horizontal)
      // that makes the day division stand out.
      final Container band = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('Today'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        band.padding,
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      );
    },
  );

  testWidgets(
    'an appointment shows a checkable bullet that toggles done '
    '(fb_1781099457246946)',
    (WidgetTester tester) async {
      final DateTime now = DateTime(2026, 6, 1, 11);
      final HoldcloseDatabase db =
          HoldcloseDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      // The appointment FKs to a provider — seed it (same db) first.
      await ProviderRepository(db).upsertProvider(const Provider(
        id: 'prov-1',
        name: 'Dr Smith',
        role: ProviderRole.other,
        phone: '',
        address: '',
      ));
      final AppointmentRepository repo = AppointmentRepository(db);
      await repo.upsertAppointment(Appointment(
        id: 'appt-1',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 1, 14),
        durationMinutes: 30,
        location: '',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      ));

      final CareEvent apptEvent = CareEvent(
        id: 'evt-appt-1',
        kind: CareEventKind.appointment,
        title: 'Dr Smith',
        start: DateTime(2026, 6, 1, 14),
        patientId: _patient,
        externalRef: 'appt-1',
      );

      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ProviderScope(
        overrides: <Override>[
          homeClockProvider.overrideWithValue(() => now),
          patientTimelineEventsProvider
              .overrideWith((Ref ref) async => <CareEvent>[apptEvent]),
          appointmentRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          theme: holdcloseLightTheme,
          home: const Scaffold(
            body: SingleChildScrollView(child: ScheduleCard()),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final Finder checkbox =
          find.byKey(ScheduleCard.doneCheckboxKey('evt-appt-1'));
      expect(checkbox, findsOneWidget);
      // Starts unchecked (upcoming).
      expect(
        find.descendant(
            of: checkbox, matching: find.byIcon(Icons.radio_button_unchecked)),
        findsOneWidget,
      );

      // A11y (UIUX_REVIEW): the control carries an explicit Semantics node
      // announcing it as an unchecked button with the appointment name
      // ("Mark done. Dr Smith"), and offers a ≥44px hit target.
      final Semantics semantics = tester.widget<Semantics>(
        find.descendant(of: checkbox, matching: find.byType(Semantics)).first,
      );
      expect(semantics.properties.label, 'Mark done. Dr Smith');
      expect(semantics.properties.button, isTrue);
      expect(semantics.properties.checked, isFalse);
      final Size hitSize = tester.getSize(
        find.descendant(of: checkbox, matching: find.byType(SizedBox)).first,
      );
      expect(hitSize.width, greaterThanOrEqualTo(44));
      expect(hitSize.height, greaterThanOrEqualTo(44));

      await tester.tap(checkbox);
      await tester.pumpAndSettle();

      // Persisted as completed AND the bullet filled in.
      final Appointment? after = await repo.getAppointment('appt-1');
      expect(after?.status, AppointmentStatus.completed);
      expect(
        find.descendant(
          of: find.byKey(ScheduleCard.doneCheckboxKey('evt-appt-1')),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );

      // The successful mark-done closes its loop with a confirmation
      // SnackBar, and the Semantics now report the checked state.
      expect(find.text('Marked "Dr Smith" as done.'), findsOneWidget);
      final Semantics checkedSemantics = tester.widget<Semantics>(
        find.descendant(of: checkbox, matching: find.byType(Semantics)).first,
      );
      expect(checkedSemantics.properties.label, 'Mark not done. Dr Smith');
      expect(checkedSemantics.properties.checked, isTrue);

      // Toggling back to not-done confirms the reverse.
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      final Appointment? reverted = await repo.getAppointment('appt-1');
      expect(reverted?.status, AppointmentStatus.upcoming);
      expect(find.text('Marked "Dr Smith" as not done.'), findsOneWidget);
    },
  );
}

import 'package:holdclose/models/care_event.dart';
import 'package:holdclose/models/caregiver.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart'
    show assignableCaregiversProvider;
import 'package:holdclose/providers/patient_timeline_provider.dart';
import 'package:holdclose/screens/team/calendar_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The calendar screen is shared: the Care Circle reaches it at
/// `/team/calendar`, the Care hub's "Schedule" tile via
/// `/team/calendar?from=medical`. After the 2026-06-06 IA refactor the
/// fromMedical/Care-Circle breadcrumb duality is gone — the screen ALWAYS
/// renders `Home › Care › Schedule` with a "Back to Care" affordance. The
/// `fromMedical` constructor param still exists (route compatibility) but
/// no longer changes the chrome. Pumped under a plain MaterialApp (no
/// router) — the header renders; its crumb taps only fire on tap.

final DateTime _now = DateTime(2026, 6, 3, 8);

Future<void> _pump(WidgetTester tester, {required bool fromMedical}) async {
  await tester.binding.setSurfaceSize(const Size(460, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        careEventsProvider
            .overrideWith((Ref ref) async => const <CareEvent>[]),
        patientTimelineEventsProvider
            .overrideWith((Ref ref) async => const <CareEvent>[]),
        calendarClockProvider.overrideWithValue(() => _now),
        assignableCaregiversProvider
            .overrideWith((Ref ref) async => const <Caregiver>[]),
      ],
      child: MaterialApp(home: CalendarScreen(fromMedical: fromMedical)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Care entry shows the Care › Schedule breadcrumb',
    (WidgetTester tester) async {
      await _pump(tester, fromMedical: true);
      // "Schedule" appears twice: terminal crumb + title.
      expect(find.text('Schedule'), findsNWidgets(2));
      // The tappable parent 'Care' crumb is the back affordance.
      expect(find.widgetWithText(InkWell, 'Care'), findsOneWidget);
      // The old Care-Circle/Medical duality is gone.
      expect(find.text('Care Circle'), findsNothing);
      expect(find.text('Medical'), findsNothing);
    },
  );

  testWidgets(
    'default (non-Care) entry shows the same Care › Schedule breadcrumb',
    (WidgetTester tester) async {
      await _pump(tester, fromMedical: false);
      // fromMedical no longer changes the chrome — identical to the
      // fromMedical case above.
      expect(find.text('Schedule'), findsNWidgets(2));
      expect(find.widgetWithText(InkWell, 'Care'), findsOneWidget);
      expect(find.text('Care Circle'), findsNothing);
      expect(find.text('Medical'), findsNothing);
    },
  );
}

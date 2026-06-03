import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/providers/care_events_provider.dart';
import 'package:careblazers/providers/patient_timeline_provider.dart';
import 'package:careblazers/screens/team/calendar_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

// Fixed "now" → the visible week is Sun May 31 → Sat Jun 6, 2026.
final DateTime _now = DateTime(2026, 6, 3, 8);

CareEvent _event({
  required String id,
  required CareEventKind kind,
  required String title,
  required DateTime start,
  DateTime? end,
}) =>
    CareEvent(
      id: id,
      kind: kind,
      title: title,
      start: start,
      end: end,
      patientId: _patientId,
      externalRef: kind == CareEventKind.note ? null : id,
    );

// One block per kind, spread across the seven days and clustered in the
// morning hours so they sit in the golden's viewport.
List<CareEvent> _richWeek() => <CareEvent>[
      _event(
        id: 'e1',
        kind: CareEventKind.appointment,
        title: 'Dr. Patel',
        start: DateTime(2026, 5, 31, 8),
        end: DateTime(2026, 5, 31, 9),
      ),
      _event(
        id: 'e2',
        kind: CareEventKind.task,
        title: 'Refill meds',
        start: DateTime(2026, 6, 1, 9),
        end: DateTime(2026, 6, 1, 10),
      ),
      _event(
        id: 'e3',
        kind: CareEventKind.shift,
        title: 'Morning shift',
        start: DateTime(2026, 6, 2, 7),
        end: DateTime(2026, 6, 2, 11),
      ),
      _event(
        id: 'e4',
        kind: CareEventKind.note,
        title: 'Pick up groceries',
        start: DateTime(2026, 6, 3, 10),
      ),
      _event(
        id: 'e5',
        kind: CareEventKind.appointment,
        title: 'Neurology',
        start: DateTime(2026, 6, 4, 8, 30),
        end: DateTime(2026, 6, 4, 9, 15),
      ),
      _event(
        id: 'e6',
        kind: CareEventKind.shift,
        title: 'Maria covers',
        start: DateTime(2026, 6, 5, 6),
        end: DateTime(2026, 6, 5, 10),
      ),
      _event(
        id: 'e7',
        kind: CareEventKind.note,
        title: 'Call insurance',
        start: DateTime(2026, 6, 6, 9, 30),
      ),
    ];

Widget _host(List<CareEvent> events) {
  return ProviderScope(
    overrides: <Override>[
      careEventsProvider.overrideWith((Ref ref) async => events),
      patientTimelineEventsProvider
          .overrideWith((Ref ref) async => const <CareEvent>[]),
      calendarClockProvider.overrideWithValue(() => _now),
    ],
    child: SizedBox(
      width: 460,
      height: 820,
      child: MaterialApp(
        home: const CalendarScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('CalendarScreen golden', () {
    goldenTest(
      'renders an event-rich week',
      fileName: 'calendar_screen_rich_week',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'event-rich week (Phase 14.29)',
            child: _host(_richWeek()),
          ),
        ],
      ),
    );
  });
}

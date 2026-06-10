import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/appointment.dart' show AppointmentStatus;
import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/providers/home_clock_provider.dart';
import 'package:careblazers/providers/patient_timeline_provider.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/schedule_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Golden of the populated Home Schedule card — the day-section bands
/// (Today / Tomorrow), the window-grouped medications headed
/// "Morning Medication · 8:00 AM", and an appointment interleaved between
/// two med windows (windows need not be adjacent). No `theme:` so
/// google_fonts stays off the network under `flutter test`; the card
/// pulls brand colors straight off [careblazersColors].

const String _patient = 'demo-patient-mary';

final DateTime _now = DateTime(2026, 6, 1, 16); // Mon 4pm

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

final List<CareEvent> _events = <CareEvent>[
  // Today — Morning meds, already given.
  _dose(
    id: 'd1',
    med: 'Ibuprofen',
    start: DateTime(2026, 6, 1, 8, 5),
    slot: DateTime(2026, 6, 1, 8),
    window: 'Morning',
    taken: true,
  ),
  _dose(
    id: 'd2',
    med: 'Tylenol',
    start: DateTime(2026, 6, 1, 8, 5),
    slot: DateTime(2026, 6, 1, 8),
    window: 'Morning',
    taken: true,
  ),
  // Today — an appointment between the two med windows.
  CareEvent(
    id: 'a1',
    kind: CareEventKind.appointment,
    title: 'Dr. Ortega',
    start: DateTime(2026, 6, 1, 13),
    patientId: _patient,
    externalRef: 'appt-1',
  ),
  // Today — Evening meds, still due.
  _dose(
    id: 'd3',
    med: 'Ibuprofen',
    start: DateTime(2026, 6, 1, 18),
    slot: DateTime(2026, 6, 1, 18),
    window: 'Evening',
    taken: false,
  ),
  _dose(
    id: 'd4',
    med: 'Tylenol',
    start: DateTime(2026, 6, 1, 18),
    slot: DateTime(2026, 6, 1, 18),
    window: 'Evening',
    taken: false,
  ),
  // Tomorrow — Morning meds.
  _dose(
    id: 'd5',
    med: 'Ibuprofen',
    start: DateTime(2026, 6, 2, 8),
    slot: DateTime(2026, 6, 2, 8),
    window: 'Morning',
    taken: false,
  ),
  _dose(
    id: 'd6',
    med: 'Tylenol',
    start: DateTime(2026, 6, 2, 8),
    slot: DateTime(2026, 6, 2, 8),
    window: 'Morning',
    taken: false,
  ),
];

void main() {
  group('ScheduleCard golden', () {
    goldenTest(
      'day-section bands over window-grouped medications',
      fileName: 'schedule_card_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'today + tomorrow',
            child: ProviderScope(
              overrides: <Override>[
                homeClockProvider.overrideWithValue(() => _now),
                patientTimelineEventsProvider
                    .overrideWith((Ref ref) async => _events),
                // Avoid hitting the real appointment DB in the golden env.
                scheduleAppointmentStatusProvider.overrideWith(
                  (Ref ref) async => const <String, AppointmentStatus>{},
                ),
              ],
              child: SizedBox(
                width: 390,
                height: 640,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  home: ColoredBox(
                    color: careblazersColors.background,
                    child: const Scaffold(
                      backgroundColor: Colors.transparent,
                      body: Padding(
                        padding: EdgeInsets.all(16),
                        child: ScheduleCard(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

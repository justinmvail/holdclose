import 'package:holdclose/models/care_event.dart';
import 'package:holdclose/widgets/home/schedule_card.dart';
import 'package:flutter_test/flutter_test.dart';

const String _patient = 'demo-patient-mary';

CareEvent _e({
  required String id,
  required DateTime start,
  CareEventKind kind = CareEventKind.appointment,
  String title = 'event',
}) =>
    CareEvent(
      id: id,
      kind: kind,
      title: title,
      start: start,
      patientId: _patient,
    );

void main() {
  // Pinned wall clock used across the suite: Mon Jun 1, 2026 11:00.
  final DateTime now = DateTime(2026, 6, 1, 11, 0);

  group('ScheduleCard.bucketSchedule', () {
    test('separates today and tomorrow, dropping later days', () {
      final List<CareEvent> events = <CareEvent>[
        // Already happened earlier today — still belongs in "Today".
        _e(id: 'past', start: DateTime(2026, 6, 1, 8)),
        // Later today.
        _e(id: 'today', start: DateTime(2026, 6, 1, 14)),
        // Tomorrow.
        _e(id: 'tmrw', start: DateTime(2026, 6, 2, 9)),
        // Day after tomorrow — dropped (card looks one day ahead).
        _e(id: 'later', start: DateTime(2026, 6, 3, 9)),
        // Later in the week (Friday) — dropped.
        _e(id: 'week', start: DateTime(2026, 6, 5, 9)),
      ];
      final ({List<CareEvent> today, List<CareEvent> tomorrow}) buckets =
          bucketSchedule(events, now);

      expect(
        buckets.today.map((CareEvent e) => e.id),
        <String>['past', 'today'],
      );
      expect(buckets.tomorrow.map((CareEvent e) => e.id), <String>['tmrw']);
    });

    test('drops events before today and from the day after tomorrow on', () {
      final List<CareEvent> events = <CareEvent>[
        // Yesterday — dropped.
        _e(id: 'yesterday', start: DateTime(2026, 5, 31, 9)),
        // Day after tomorrow — dropped.
        _e(id: 'day-after', start: DateTime(2026, 6, 3, 9)),
        // In-window control.
        _e(id: 'today', start: DateTime(2026, 6, 1, 14)),
      ];
      final ({List<CareEvent> today, List<CareEvent> tomorrow}) buckets =
          bucketSchedule(events, now);

      expect(buckets.today.map((CareEvent e) => e.id), <String>['today']);
      expect(buckets.tomorrow, isEmpty);
    });

    test('returns two empty buckets when the input is empty', () {
      final ({List<CareEvent> today, List<CareEvent> tomorrow}) buckets =
          bucketSchedule(const <CareEvent>[], now);
      expect(buckets.today, isEmpty);
      expect(buckets.tomorrow, isEmpty);
    });
  });
}

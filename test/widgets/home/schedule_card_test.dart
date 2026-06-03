import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/widgets/home/schedule_card.dart';
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
  // Sun-anchored week ends Sat Jun 6.
  final DateTime now = DateTime(2026, 6, 1, 11, 0);

  group('ScheduleCard.bucketSchedule', () {
    test('separates today, tomorrow, and the rest of this week', () {
      final List<CareEvent> events = <CareEvent>[
        // Already happened earlier today — still belongs in "Today".
        _e(id: 'past', start: DateTime(2026, 6, 1, 8)),
        // Later today.
        _e(id: 'today', start: DateTime(2026, 6, 1, 14)),
        // Tomorrow.
        _e(id: 'tmrw', start: DateTime(2026, 6, 2, 9)),
        // Later in the week (Friday).
        _e(id: 'week', start: DateTime(2026, 6, 5, 9)),
      ];
      final ({
        List<CareEvent> today,
        List<CareEvent> tomorrow,
        List<CareEvent> thisWeek,
      }) buckets = bucketSchedule(events, now);

      expect(
        buckets.today.map((CareEvent e) => e.id),
        <String>['past', 'today'],
      );
      expect(buckets.tomorrow.map((CareEvent e) => e.id), <String>['tmrw']);
      expect(buckets.thisWeek.map((CareEvent e) => e.id), <String>['week']);
    });

    test('drops events before today and after Saturday', () {
      final List<CareEvent> events = <CareEvent>[
        // Yesterday — dropped.
        _e(id: 'yesterday', start: DateTime(2026, 5, 31, 9)),
        // Next Sunday (next week) — dropped.
        _e(id: 'next-sun', start: DateTime(2026, 6, 7, 9)),
        // In-window control.
        _e(id: 'today', start: DateTime(2026, 6, 1, 14)),
      ];
      final ({
        List<CareEvent> today,
        List<CareEvent> tomorrow,
        List<CareEvent> thisWeek,
      }) buckets = bucketSchedule(events, now);

      expect(buckets.today.map((CareEvent e) => e.id), <String>['today']);
      expect(buckets.tomorrow, isEmpty);
      expect(buckets.thisWeek, isEmpty);
    });

    test('returns three empty buckets when the input is empty', () {
      final ({
        List<CareEvent> today,
        List<CareEvent> tomorrow,
        List<CareEvent> thisWeek,
      }) buckets = bucketSchedule(const <CareEvent>[], now);
      expect(buckets.today, isEmpty);
      expect(buckets.tomorrow, isEmpty);
      expect(buckets.thisWeek, isEmpty);
    });

    test('Saturday "now" leaves zero days remaining in this week', () {
      final DateTime saturday = DateTime(2026, 6, 6, 11);
      final List<CareEvent> events = <CareEvent>[
        // Saturday afternoon — still today.
        _e(id: 'sat-pm', start: DateTime(2026, 6, 6, 18)),
        // Sunday morning — tomorrow (next week starts).
        _e(id: 'sun-am', start: DateTime(2026, 6, 7, 9)),
        // Following Tuesday — outside this week.
        _e(id: 'next-tue', start: DateTime(2026, 6, 9, 9)),
      ];
      final ({
        List<CareEvent> today,
        List<CareEvent> tomorrow,
        List<CareEvent> thisWeek,
      }) buckets = bucketSchedule(events, saturday);

      expect(buckets.today.map((CareEvent e) => e.id), <String>['sat-pm']);
      expect(buckets.tomorrow.map((CareEvent e) => e.id), <String>['sun-am']);
      expect(buckets.thisWeek, isEmpty);
    });
  });
}

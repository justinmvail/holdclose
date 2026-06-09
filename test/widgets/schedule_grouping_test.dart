import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/widgets/schedule_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-function coverage for [groupDoseEventsByWindow] — the shared
/// transform the Home Schedule card and the Care Team Calendar both use to
/// fold per-dose timeline events into one row per medication window.

CareEvent _dose({
  required String id,
  required String med,
  required DateTime start,
  DateTime? slot,
  String? window,
  required bool taken,
}) =>
    CareEvent(
      id: id,
      kind: taken ? CareEventKind.doseLogged : CareEventKind.doseScheduled,
      title: med,
      start: start,
      patientId: 'p',
      windowLabel: window,
      windowSlot: slot,
    );

CareEvent _appt(String id, DateTime start) => CareEvent(
      id: id,
      kind: CareEventKind.appointment,
      title: 'Appt',
      start: start,
      patientId: 'p',
    );

void main() {
  group('groupDoseEventsByWindow', () {
    test('folds doses sharing a window slot into one group, anchored at the '
        'slot (not the logged time)', () {
      final DateTime slot = DateTime(2026, 6, 1, 8);
      final List<ScheduleRow> rows = groupDoseEventsByWindow(<CareEvent>[
        _dose(
            id: 'a',
            med: 'Tylenol',
            start: DateTime(2026, 6, 1, 14, 15), // logged off-anchor
            slot: slot,
            window: 'Morning',
            taken: true),
        _dose(
            id: 'b',
            med: 'Ibuprofen',
            start: DateTime(2026, 6, 1, 14, 15),
            slot: slot,
            window: 'Morning',
            taken: false),
      ]);

      expect(rows, hasLength(1));
      final DoseWindowGroup g = (rows.single as DoseGroupRow).group;
      expect(g.windowLabel, 'Morning');
      expect(g.start, slot); // anchored at the 8am slot, not 2:15pm
      // Alphabetical, per-med taken status preserved.
      expect(g.meds.map((({String name, bool taken}) m) => m.name).toList(),
          <String>['Ibuprofen', 'Tylenol']);
      expect(g.meds.firstWhere((({String name, bool taken}) m) =>
              m.name == 'Tylenol').taken, isTrue);
      expect(g.meds.firstWhere((({String name, bool taken}) m) =>
              m.name == 'Ibuprofen').taken, isFalse);
      expect(g.allLogged, isFalse);
      expect(g.firstEventId, 'a');
    });

    test('different window slots make separate groups', () {
      final List<ScheduleRow> rows = groupDoseEventsByWindow(<CareEvent>[
        _dose(
            id: 'm',
            med: 'A',
            start: DateTime(2026, 6, 1, 8),
            slot: DateTime(2026, 6, 1, 8),
            window: 'Morning',
            taken: false),
        _dose(
            id: 'e',
            med: 'B',
            start: DateTime(2026, 6, 1, 18),
            slot: DateTime(2026, 6, 1, 18),
            window: 'Evening',
            taken: false),
      ]);
      expect(rows.whereType<DoseGroupRow>(), hasLength(2));
    });

    test('non-dose events pass through as EventRow in effective-time order',
        () {
      final List<ScheduleRow> rows = groupDoseEventsByWindow(<CareEvent>[
        _appt('x', DateTime(2026, 6, 1, 9)),
        _dose(
            id: 'd',
            med: 'A',
            start: DateTime(2026, 6, 1, 8),
            slot: DateTime(2026, 6, 1, 8),
            window: 'Morning',
            taken: false),
      ]);
      // The 8am dose slot sorts before the 9am appointment.
      expect(rows, hasLength(2));
      expect(rows[0], isA<DoseGroupRow>());
      expect(rows[1], isA<EventRow>());
      expect((rows[1] as EventRow).event.id, 'x');
    });

    test('legacy doses without a window slot fall back to wall-clock-minute '
        'grouping', () {
      final List<ScheduleRow> rows = groupDoseEventsByWindow(<CareEvent>[
        _dose(id: 'a', med: 'A', start: DateTime(2026, 6, 1, 8), taken: false),
        _dose(id: 'b', med: 'B', start: DateTime(2026, 6, 1, 8), taken: false),
        _dose(id: 'c', med: 'C', start: DateTime(2026, 6, 1, 9), taken: false),
      ]);
      final List<DoseGroupRow> groups =
          rows.whereType<DoseGroupRow>().toList();
      expect(groups, hasLength(2));
      expect(groups[0].group.windowLabel, isNull);
      expect(groups[0].group.meds.map((({String name, bool taken}) m) => m.name),
          <String>['A', 'B']);
      expect(groups[1].group.meds.map((({String name, bool taken}) m) => m.name),
          <String>['C']);
    });

    test('a fully-logged window reports allLogged', () {
      final DateTime slot = DateTime(2026, 6, 1, 8);
      final List<ScheduleRow> rows = groupDoseEventsByWindow(<CareEvent>[
        _dose(
            id: 'a',
            med: 'A',
            start: slot,
            slot: slot,
            window: 'Morning',
            taken: true),
        _dose(
            id: 'b',
            med: 'B',
            start: slot,
            slot: slot,
            window: 'Morning',
            taken: true),
      ]);
      expect((rows.single as DoseGroupRow).group.allLogged, isTrue);
    });

    test('an empty input yields no rows', () {
      expect(groupDoseEventsByWindow(const <CareEvent>[]), isEmpty);
    });
  });
}

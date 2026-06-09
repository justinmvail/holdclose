import 'package:careblazers/models/medication.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

/// Unit coverage for the pure window-grouping helpers the Home
/// medications card + dose-log screen share ([groupDosesByWindow],
/// [windowClockLabel]). No widget tree, no DB — just the grouping math.

const String _patient = 'demo-patient-mary';

Medication _med(String id, String name) => Medication(
      id: id,
      name: name,
      dosage: '10 mg',
      route: MedicationRoute.oral,
    );

DoseWindow _window(
  String id,
  String label, {
  TimeOfDay? anchor,
  required int sortOrder,
}) =>
    DoseWindow(
      id: id,
      patientId: _patient,
      label: label,
      anchorTime: anchor,
      sortOrder: sortOrder,
    );

MedicationWindowEntry _entry(String id, String medId, String windowId) =>
    MedicationWindowEntry(
      id: id,
      medicationId: medId,
      windowId: windowId,
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 1, 1),
    );

ScheduledDose _dose(Medication med, DoseWindow window, DateTime at) =>
    ScheduledDose(
      medication: med,
      window: window,
      entry: _entry('entry-${med.id}-${window.id}', med.id, window.id),
      scheduledFor: at,
    );

void main() {
  final DoseWindow morning =
      _window('w-morning', 'Morning', anchor: const TimeOfDay(hour: 8, minute: 0), sortOrder: 0);
  final DoseWindow evening =
      _window('w-evening', 'Evening', anchor: const TimeOfDay(hour: 18, minute: 0), sortOrder: 2);
  final DoseWindow asNeeded =
      _window('w-prn', 'As needed', anchor: null, sortOrder: 4);

  final Medication ibuprofen = _med('m-ibu', 'Ibuprofen');
  final Medication tylenol = _med('m-tyl', 'Tylenol');

  group('groupDosesByWindow', () {
    test('buckets doses under their window', () {
      final List<DoseWindowGroup> groups = groupDosesByWindow(<ScheduledDose>[
        _dose(ibuprofen, morning, DateTime(2026, 6, 1, 8)),
        _dose(tylenol, morning, DateTime(2026, 6, 1, 8)),
        _dose(ibuprofen, evening, DateTime(2026, 6, 1, 18)),
      ]);

      expect(groups.map((DoseWindowGroup g) => g.window.label),
          <String>['Morning', 'Evening']);
      expect(groups.first.doses.map((ScheduledDose d) => d.medication.name),
          <String>['Ibuprofen', 'Tylenol']);
      expect(groups.last.doses.single.medication.name, 'Ibuprofen');
    });

    test('orders windows by anchor time ascending', () {
      // Feed evening first; the helper still sorts morning before evening.
      final List<DoseWindowGroup> groups = groupDosesByWindow(<ScheduledDose>[
        _dose(ibuprofen, evening, DateTime(2026, 6, 1, 18)),
        _dose(ibuprofen, morning, DateTime(2026, 6, 1, 8)),
      ]);
      expect(groups.map((DoseWindowGroup g) => g.window.label),
          <String>['Morning', 'Evening']);
    });

    test('sorts an as-needed (null-anchor) window last', () {
      final List<DoseWindowGroup> groups = groupDosesByWindow(<ScheduledDose>[
        _dose(ibuprofen, asNeeded, DateTime(2026, 6, 1, 12)),
        _dose(tylenol, evening, DateTime(2026, 6, 1, 18)),
        _dose(ibuprofen, morning, DateTime(2026, 6, 1, 8)),
      ]);
      expect(groups.map((DoseWindowGroup g) => g.window.label),
          <String>['Morning', 'Evening', 'As needed']);
    });

    test('returns an empty list for no doses', () {
      expect(groupDosesByWindow(const <ScheduledDose>[]), isEmpty);
    });
  });

  group('windowClockLabel', () {
    test('formats a morning anchor in 12-hour time', () {
      expect(windowClockLabel(morning), '8:00 AM');
    });

    test('formats an evening anchor in 12-hour time', () {
      expect(windowClockLabel(evening), '6:00 PM');
    });

    test('renders midnight as 12:00 AM and noon as 12:00 PM', () {
      expect(
        windowClockLabel(_window('w-mid', 'Midnight',
            anchor: const TimeOfDay(hour: 0, minute: 0), sortOrder: 0)),
        '12:00 AM',
      );
      expect(
        windowClockLabel(_window('w-noon', 'Noon',
            anchor: const TimeOfDay(hour: 12, minute: 5), sortOrder: 1)),
        '12:05 PM',
      );
    });

    test('labels an anchor-less window "As needed"', () {
      expect(windowClockLabel(asNeeded), 'As needed');
    });
  });
}

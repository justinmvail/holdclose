import 'package:holdclose/models/medication.dart';
import 'package:holdclose/screens/team/activity_screen.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

/// Pure-function coverage for [doseWindowActivityFeedItems] — the transform
/// that folds the Care Team activity feed's acted-on doses into one row per
/// medication window (parity with the Calendar + Home schedule).

const String _patient = 'demo-patient-mary';

Medication _med(String id, String name, {String dosage = '10 mg'}) =>
    Medication(id: id, name: name, dosage: dosage, route: MedicationRoute.oral);

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

MedicationWindowEntry _entry(String medId, String windowId) =>
    MedicationWindowEntry(
      id: 'entry-$medId-$windowId',
      medicationId: medId,
      windowId: windowId,
      daysOfWeek: const <int>{},
      startsOn: DateTime(2026, 1, 1),
    );

ScheduledDose _dose(
  Medication med,
  DoseWindow window,
  DateTime at, {
  required DoseStatus status,
  DateTime? takenAt,
}) =>
    ScheduledDose(
      medication: med,
      window: window,
      entry: _entry(med.id, window.id),
      scheduledFor: at,
      log: DoseLog(
        id: 'log-${med.id}-${window.id}',
        medicationId: med.id,
        scheduledFor: at,
        takenAt: takenAt,
        status: status,
      ),
    );

void main() {
  final DoseWindow morning = _window('w-morning', 'Morning',
      anchor: const TimeOfDay(hour: 8, minute: 0), sortOrder: 0);
  final DoseWindow evening = _window('w-evening', 'Evening',
      anchor: const TimeOfDay(hour: 18, minute: 0), sortOrder: 2);
  final Medication donepezil = _med('m-don', 'Donepezil');
  final Medication metformin = _med('m-met', 'Metformin', dosage: '500 mg');

  group('doseWindowActivityFeedItems', () {
    test("folds a window's acted doses into one item with each med + status",
        () {
      final List<ActivityFeedItem> items =
          doseWindowActivityFeedItems(<ScheduledDose>[
        _dose(donepezil, morning, DateTime(2026, 6, 1, 8),
            status: DoseStatus.taken, takenAt: DateTime(2026, 6, 1, 8, 5)),
        _dose(metformin, morning, DateTime(2026, 6, 1, 8),
            status: DoseStatus.skipped),
      ]);

      expect(items, hasLength(1));
      final ActivityFeedItem item = items.single;
      expect(item.category, ActivityCategory.dose);
      expect(item.route, '/medications/today');
      expect(item.doseWindow, isNotNull);
      expect(item.doseWindow!.windowLabel, 'Morning');
      expect(
          item.doseWindow!.meds
              .map((ActivityDoseEntry m) => m.name)
              .toList(),
          <String>['Donepezil 10 mg', 'Metformin 500 mg']);
      expect(
          item.doseWindow!.meds
              .map((ActivityDoseEntry m) => m.status)
              .toList(),
          <DoseStatus>[DoseStatus.taken, DoseStatus.skipped]);
      // Anchored at the window's most recent action (the 8:05 taken stamp).
      expect(item.createdAt, DateTime(2026, 6, 1, 8, 5));
    });

    test('separate windows make separate items, morning before evening', () {
      final List<ActivityFeedItem> items =
          doseWindowActivityFeedItems(<ScheduledDose>[
        _dose(donepezil, evening, DateTime(2026, 6, 1, 18),
            status: DoseStatus.taken, takenAt: DateTime(2026, 6, 1, 18)),
        _dose(donepezil, morning, DateTime(2026, 6, 1, 8),
            status: DoseStatus.taken, takenAt: DateTime(2026, 6, 1, 8)),
      ]);
      expect(
          items.map((ActivityFeedItem i) => i.doseWindow!.windowLabel).toList(),
          <String>['Morning', 'Evening']);
    });

    test('falls back to scheduledFor when a logged dose has no takenAt', () {
      final List<ActivityFeedItem> items =
          doseWindowActivityFeedItems(<ScheduledDose>[
        _dose(donepezil, morning, DateTime(2026, 6, 1, 8),
            status: DoseStatus.missed),
      ]);
      expect(items.single.createdAt, DateTime(2026, 6, 1, 8));
      expect(items.single.doseWindow!.meds.single.status, DoseStatus.missed);
    });

    test('an empty list yields no items', () {
      expect(doseWindowActivityFeedItems(const <ScheduledDose>[]), isEmpty);
    });
  });
}

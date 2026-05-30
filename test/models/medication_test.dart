import 'package:careblazers/models/medication.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---- TimeOfDayJsonConverter --------------------------------------------

  group('TimeOfDayJsonConverter', () {
    const TimeOfDayJsonConverter c = TimeOfDayJsonConverter();

    test('serialises zero-padded HH:mm', () {
      expect(c.toJson(const TimeOfDay(hour: 8, minute: 0)), '08:00');
      expect(c.toJson(const TimeOfDay(hour: 0, minute: 5)), '00:05');
      expect(c.toJson(const TimeOfDay(hour: 23, minute: 59)), '23:59');
    });

    test('parses HH:mm back to TimeOfDay', () {
      expect(c.fromJson('08:00'), const TimeOfDay(hour: 8, minute: 0));
      expect(c.fromJson('00:05'), const TimeOfDay(hour: 0, minute: 5));
      expect(c.fromJson('23:59'), const TimeOfDay(hour: 23, minute: 59));
    });

    test('round-trips midnight + noon', () {
      const TimeOfDay midnight = TimeOfDay(hour: 0, minute: 0);
      const TimeOfDay noon = TimeOfDay(hour: 12, minute: 0);
      expect(c.fromJson(c.toJson(midnight)), midnight);
      expect(c.fromJson(c.toJson(noon)), noon);
    });
  });

  // ---- MedicationRoute enum ----------------------------------------------

  group('MedicationRoute', () {
    test('exposes the four spec values', () {
      expect(MedicationRoute.values, hasLength(4));
      expect(
        MedicationRoute.values,
        containsAll(<MedicationRoute>[
          MedicationRoute.oral,
          MedicationRoute.topical,
          MedicationRoute.injection,
          MedicationRoute.other,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final MedicationRoute route in MedicationRoute.values) {
        final Medication med = Medication(
          id: 'm-${route.name}',
          name: 'Test',
          dosage: '1 tab',
          route: route,
        );
        expect(med.toJson()['route'], route.name);
      }
    });
  });

  // ---- FrequencyKind enum ------------------------------------------------

  group('FrequencyKind', () {
    test('exposes the four spec values', () {
      expect(FrequencyKind.values, hasLength(4));
      expect(
        FrequencyKind.values,
        containsAll(<FrequencyKind>[
          FrequencyKind.daily,
          FrequencyKind.twiceDaily,
          FrequencyKind.weekly,
          FrequencyKind.asNeeded,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final FrequencyKind kind in FrequencyKind.values) {
        final DoseSchedule s = DoseSchedule(
          id: 's-${kind.name}',
          medicationId: 'med-001',
          frequencyKind: kind,
          timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
          daysOfWeek: const <int>{1, 2, 3, 4, 5},
          startsOn: DateTime.utc(2026, 6, 1),
        );
        expect(s.toJson()['frequencyKind'], kind.name);
      }
    });
  });

  // ---- DoseStatus enum ---------------------------------------------------

  group('DoseStatus', () {
    test('exposes the four spec values', () {
      expect(DoseStatus.values, hasLength(4));
      expect(
        DoseStatus.values,
        containsAll(<DoseStatus>[
          DoseStatus.taken,
          DoseStatus.missed,
          DoseStatus.skipped,
          DoseStatus.late,
        ]),
      );
    });
  });

  // ---- Medication JSON round-trip ---------------------------------------

  group('Medication JSON round-trip', () {
    test('round-trips with every optional field populated', () {
      const Medication med = Medication(
        id: 'med-001',
        name: 'Donepezil',
        dosage: '10 mg',
        route: MedicationRoute.oral,
        prescriber: 'Dr. Ortega',
        notes: 'Take with food.',
      );
      expect(Medication.fromJson(med.toJson()), equals(med));
    });

    test('round-trips with prescriber + notes both null', () {
      const Medication med = Medication(
        id: 'med-002',
        name: 'Vitamin D',
        dosage: '2000 IU',
        route: MedicationRoute.oral,
      );
      final Medication parsed = Medication.fromJson(med.toJson());
      expect(parsed.prescriber, isNull);
      expect(parsed.notes, isNull);
      expect(parsed, equals(med));
    });

    test('round-trips topical / injection / other routes', () {
      for (final MedicationRoute route in <MedicationRoute>[
        MedicationRoute.topical,
        MedicationRoute.injection,
        MedicationRoute.other,
      ]) {
        final Medication med = Medication(
          id: 'med-${route.name}',
          name: 'Test',
          dosage: '1 dose',
          route: route,
        );
        expect(Medication.fromJson(med.toJson()), equals(med));
      }
    });
  });

  // ---- DoseSchedule JSON round-trip --------------------------------------

  group('DoseSchedule JSON round-trip', () {
    test('round-trips a daily morning schedule', () {
      final DoseSchedule s = DoseSchedule(
        id: 'sched-001',
        medicationId: 'med-001',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime.utc(2026, 6, 1),
      );
      expect(DoseSchedule.fromJson(s.toJson()), equals(s));
    });

    test('round-trips a twice-daily schedule with two times', () {
      final DoseSchedule s = DoseSchedule(
        id: 'sched-002',
        medicationId: 'med-001',
        frequencyKind: FrequencyKind.twiceDaily,
        timesOfDay: const <TimeOfDay>[
          TimeOfDay(hour: 8, minute: 0),
          TimeOfDay(hour: 20, minute: 0),
        ],
        daysOfWeek: const <int>{},
        startsOn: DateTime.utc(2026, 6, 1),
      );
      final DoseSchedule parsed = DoseSchedule.fromJson(s.toJson());
      expect(parsed.timesOfDay, hasLength(2));
      expect(parsed.timesOfDay.first, const TimeOfDay(hour: 8, minute: 0));
      expect(parsed.timesOfDay.last, const TimeOfDay(hour: 20, minute: 0));
      expect(parsed, equals(s));
    });

    test('round-trips a weekly schedule with daysOfWeek populated', () {
      // Mondays + Thursdays only.
      final DoseSchedule s = DoseSchedule(
        id: 'sched-003',
        medicationId: 'med-002',
        frequencyKind: FrequencyKind.weekly,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 30)],
        daysOfWeek: const <int>{1, 4},
        startsOn: DateTime.utc(2026, 6, 1),
        endsOn: DateTime.utc(2026, 9, 1),
      );
      final DoseSchedule parsed = DoseSchedule.fromJson(s.toJson());
      expect(parsed.daysOfWeek, <int>{1, 4});
      expect(parsed.endsOn, DateTime.utc(2026, 9, 1));
      expect(parsed, equals(s));
    });

    test('round-trips an as-needed schedule with empty times + days', () {
      final DoseSchedule s = DoseSchedule(
        id: 'sched-004',
        medicationId: 'med-003',
        frequencyKind: FrequencyKind.asNeeded,
        timesOfDay: const <TimeOfDay>[],
        daysOfWeek: const <int>{},
        startsOn: DateTime.utc(2026, 6, 1),
      );
      final DoseSchedule parsed = DoseSchedule.fromJson(s.toJson());
      expect(parsed.timesOfDay, isEmpty);
      expect(parsed.daysOfWeek, isEmpty);
      expect(parsed.frequencyKind, FrequencyKind.asNeeded);
      expect(parsed.endsOn, isNull);
      expect(parsed, equals(s));
    });

    test('persists timesOfDay as zero-padded HH:mm strings', () {
      final DoseSchedule s = DoseSchedule(
        id: 'sched-005',
        medicationId: 'med-001',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[
          TimeOfDay(hour: 0, minute: 5),
          TimeOfDay(hour: 9, minute: 0),
        ],
        daysOfWeek: const <int>{},
        startsOn: DateTime.utc(2026, 6, 1),
      );
      final List<dynamic> raw = s.toJson()['timesOfDay'] as List<dynamic>;
      expect(raw, <String>['00:05', '09:00']);
    });
  });

  // ---- DoseLog JSON round-trip -------------------------------------------

  group('DoseLog JSON round-trip', () {
    test('round-trips a taken dose', () {
      final DoseLog log = DoseLog(
        id: 'log-001',
        medicationId: 'med-001',
        scheduledFor: DateTime.utc(2026, 5, 30, 8),
        takenAt: DateTime.utc(2026, 5, 30, 8, 5),
        status: DoseStatus.taken,
        notes: 'Took with breakfast.',
      );
      expect(DoseLog.fromJson(log.toJson()), equals(log));
    });

    test('round-trips a missed dose with takenAt + notes null', () {
      final DoseLog log = DoseLog(
        id: 'log-002',
        medicationId: 'med-001',
        scheduledFor: DateTime.utc(2026, 5, 30, 20),
        status: DoseStatus.missed,
      );
      final DoseLog parsed = DoseLog.fromJson(log.toJson());
      expect(parsed.takenAt, isNull);
      expect(parsed.notes, isNull);
      expect(parsed.status, DoseStatus.missed);
      expect(parsed, equals(log));
    });

    test('round-trips skipped + late status values', () {
      for (final DoseStatus status in <DoseStatus>[
        DoseStatus.skipped,
        DoseStatus.late,
      ]) {
        final DoseLog log = DoseLog(
          id: 'log-${status.name}',
          medicationId: 'med-001',
          scheduledFor: DateTime.utc(2026, 5, 30, 8),
          takenAt: status == DoseStatus.late
              ? DateTime.utc(2026, 5, 30, 11)
              : null,
          status: status,
        );
        final DoseLog parsed = DoseLog.fromJson(log.toJson());
        expect(parsed.status, status);
        expect(parsed, equals(log));
      }
    });
  });
}

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MedicationRepository — TASKS.md Phase 12.2', () {
    late CareblazersDatabase db;
    late MedicationRepository repo;

    // Fixed clock: Saturday 2026-05-30 at 08:00 local time. Far enough
    // from any DST boundary in the standard test TZs that the
    // expansion arithmetic stays unambiguous.
    final DateTime now = DateTime(2026, 5, 30, 8);
    DateTime clock() => now;

    Medication donepezil() => const Medication(
          id: 'med-donepezil',
          name: 'Donepezil',
          dosage: '10 mg',
          route: MedicationRoute.oral,
          prescriber: 'Dr. Kim',
        );

    Medication memantine() => const Medication(
          id: 'med-memantine',
          name: 'Memantine',
          dosage: '10 mg',
          route: MedicationRoute.oral,
        );

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = MedicationRepository(db, clock: clock);
    });

    tearDown(() async {
      await db.close();
    });

    // ─────────────────────────────────────── CRUD round-trips ──

    test('upsertMedication / listMedications round-trip alphabetically',
        () async {
      await repo.upsertMedication(memantine());
      await repo.upsertMedication(donepezil());

      final List<Medication> rows = await repo.listMedications();
      expect(rows.map((Medication m) => m.id).toList(),
          <String>['med-donepezil', 'med-memantine']);
      expect(rows.first, donepezil());
    });

    test('getMedication returns null for an unknown id', () async {
      expect(await repo.getMedication('does-not-exist'), isNull);
    });

    test('upsertSchedule + schedulesFor round-trips a daily schedule',
        () async {
      await repo.upsertMedication(donepezil());
      final DoseSchedule sched = DoseSchedule(
        id: 'sched-1',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      );
      await repo.upsertSchedule(sched);

      final List<DoseSchedule> rows =
          await repo.schedulesFor('med-donepezil');
      expect(rows, hasLength(1));
      expect(rows.single, sched);
    });

    test('upsertDoseLog + logsFor round-trips and sorts chronologically',
        () async {
      await repo.upsertMedication(donepezil());
      final DoseLog later = DoseLog(
        id: 'log-later',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 30, 21),
        takenAt: DateTime(2026, 5, 30, 21, 5),
        status: DoseStatus.taken,
      );
      final DoseLog earlier = DoseLog(
        id: 'log-earlier',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 30, 9),
        takenAt: DateTime(2026, 5, 30, 9, 2),
        status: DoseStatus.taken,
      );
      // Insert out-of-order to prove the lifted `scheduledForMs`
      // column drives the chronological sort.
      await repo.upsertDoseLog(later);
      await repo.upsertDoseLog(earlier);

      final List<DoseLog> rows = await repo.logsFor('med-donepezil');
      expect(rows.map((DoseLog l) => l.id).toList(),
          <String>['log-earlier', 'log-later']);
    });

    test('upsertDoseLog is idempotent — same id overwrites in place',
        () async {
      await repo.upsertMedication(donepezil());
      final DateTime scheduledFor = DateTime(2026, 5, 30, 9);
      await repo.upsertDoseLog(DoseLog(
        id: 'log-1',
        medicationId: 'med-donepezil',
        scheduledFor: scheduledFor,
        status: DoseStatus.missed,
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-1',
        medicationId: 'med-donepezil',
        scheduledFor: scheduledFor,
        takenAt: DateTime(2026, 5, 30, 9, 30),
        status: DoseStatus.late,
      ));

      final List<DoseLog> rows = await repo.logsFor('med-donepezil');
      expect(rows, hasLength(1));
      expect(rows.single.status, DoseStatus.late);
      expect(rows.single.takenAt, DateTime(2026, 5, 30, 9, 30));
    });

    test('deleteSchedule + deleteDoseLog drop their rows', () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-die',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-die',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 30, 9),
        status: DoseStatus.taken,
      ));

      await repo.deleteSchedule('sched-die');
      await repo.deleteDoseLog('log-die');

      expect(await repo.schedulesFor('med-donepezil'), isEmpty);
      expect(await repo.logsFor('med-donepezil'), isEmpty);
    });

    test('deleteMedication cascades to schedules and logs', () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertMedication(memantine());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-doomed',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-doomed',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 30, 9),
        status: DoseStatus.taken,
      ));
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-survivor',
        medicationId: 'med-memantine',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 20, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));

      await repo.deleteMedication('med-donepezil');

      expect((await repo.listMedications()).map((Medication m) => m.id),
          <String>['med-memantine']);
      expect(await repo.schedulesFor('med-donepezil'), isEmpty);
      expect(await repo.logsFor('med-donepezil'), isEmpty);
      expect(await repo.schedulesFor('med-memantine'), hasLength(1));
    });

    // ─────────────────────────────────── Schedule expansion ──

    test('upcomingDoses expands a daily schedule across the next 7 days',
        () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-daily',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));

      final List<ScheduledDose> doses = await repo.upcomingDoses();

      // Clock is 2026-05-30 08:00 — first 9am occurrence is today,
      // and we cover today's 9am plus the next 6 days' 9am = 7 total.
      expect(doses, hasLength(7));
      expect(doses.first.scheduledFor, DateTime(2026, 5, 30, 9));
      expect(doses.last.scheduledFor, DateTime(2026, 6, 5, 9));
      // Sorted ascending.
      for (int i = 1; i < doses.length; i++) {
        expect(doses[i].scheduledFor.isAfter(doses[i - 1].scheduledFor),
            isTrue);
      }
    });

    test('upcomingDoses expands twiceDaily into 2 occurrences per day',
        () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-twice',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.twiceDaily,
        timesOfDay: const <TimeOfDay>[
          TimeOfDay(hour: 9, minute: 0),
          TimeOfDay(hour: 21, minute: 0),
        ],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));

      final List<ScheduledDose> doses =
          await repo.upcomingDoses(within: const Duration(days: 3));

      // Clock 2026-05-30 08:00, window ends 2026-06-02 08:00.
      // Today: 9am + 9pm. May 31: 9am + 9pm. Jun 1: 9am + 9pm. Jun 2:
      // nothing — 8am window-end is before the 9am dose. 6 doses.
      expect(doses, hasLength(6));
      expect(doses.first.scheduledFor, DateTime(2026, 5, 30, 9));
      expect(doses[1].scheduledFor, DateTime(2026, 5, 30, 21));
      expect(doses.last.scheduledFor, DateTime(2026, 6, 1, 21));
    });

    test('upcomingDoses respects FrequencyKind.weekly daysOfWeek',
        () async {
      await repo.upsertMedication(donepezil());
      // Mon (1) + Wed (3) + Fri (5) at 10am.
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-weekly',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.weekly,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 10, minute: 0)],
        daysOfWeek: const <int>{
          DateTime.monday,
          DateTime.wednesday,
          DateTime.friday,
        },
        startsOn: DateTime(2026, 5, 1),
      ));

      final List<ScheduledDose> doses = await repo.upcomingDoses();

      // From Sat 2026-05-30 08:00 through Sat 2026-06-06 08:00:
      //   Mon 2026-06-01 10:00
      //   Wed 2026-06-03 10:00
      //   Fri 2026-06-05 10:00
      expect(doses.map((ScheduledDose d) => d.scheduledFor).toList(),
          <DateTime>[
            DateTime(2026, 6, 1, 10),
            DateTime(2026, 6, 3, 10),
            DateTime(2026, 6, 5, 10),
          ]);
      for (final ScheduledDose d in doses) {
        expect(<int>{DateTime.monday, DateTime.wednesday, DateTime.friday}
            .contains(d.scheduledFor.weekday), isTrue);
      }
    });

    test('upcomingDoses skips FrequencyKind.asNeeded schedules entirely',
        () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-prn',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.asNeeded,
        timesOfDay: const <TimeOfDay>[],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));

      expect(await repo.upcomingDoses(), isEmpty);
    });

    test('upcomingDoses clamps to schedule.startsOn (future schedule)',
        () async {
      await repo.upsertMedication(donepezil());
      // Schedule doesn't kick in until 4 days from now.
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-future',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 6, 3),
      ));

      final List<ScheduledDose> doses = await repo.upcomingDoses();

      // Window 2026-05-30 08:00 → 2026-06-06 08:00; schedule active
      // from Jun 3. So Jun 3 9am, Jun 4 9am, Jun 5 9am, Jun 6 — 9am
      // is after the 08:00 window end, so excluded. 3 doses.
      expect(doses, hasLength(3));
      expect(doses.first.scheduledFor, DateTime(2026, 6, 3, 9));
      expect(doses.last.scheduledFor, DateTime(2026, 6, 5, 9));
    });

    test('upcomingDoses honours schedule.endsOn (paused schedule)',
        () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-ending',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
        endsOn: DateTime(2026, 6, 1, 12),
      ));

      final List<ScheduledDose> doses = await repo.upcomingDoses();

      // Today (May 30) 9am, May 31 9am, Jun 1 9am — then endsOn cuts
      // the rest. 3 doses.
      expect(doses, hasLength(3));
      expect(doses.last.scheduledFor, DateTime(2026, 6, 1, 9));
    });

    test('upcomingDoses excludes occurrences that already have a log row',
        () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-daily',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      // Log the first two upcoming doses as taken.
      await repo.upsertDoseLog(DoseLog(
        id: 'log-today',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 30, 9),
        takenAt: DateTime(2026, 5, 30, 9, 5),
        status: DoseStatus.taken,
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'log-tomorrow',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 31, 9),
        status: DoseStatus.skipped,
      ));

      final List<ScheduledDose> doses = await repo.upcomingDoses();

      expect(doses, hasLength(5)); // 7 daily − 2 logged.
      expect(doses.first.scheduledFor, DateTime(2026, 6, 1, 9));
      for (final ScheduledDose d in doses) {
        expect(d.log, isNull);
      }
    });

    test('upcomingDoses spans multiple medications, ascending merged',
        () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertMedication(memantine());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-morning',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-evening',
        medicationId: 'med-memantine',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 20, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));

      final List<ScheduledDose> doses =
          await repo.upcomingDoses(within: const Duration(days: 2));

      // Today 9am (don), today 8pm (mem), tomorrow 9am (don), tomorrow
      // 8pm (mem) — merged + sorted.
      expect(doses.map((ScheduledDose d) => d.medication.id).toList(),
          <String>[
            'med-donepezil',
            'med-memantine',
            'med-donepezil',
            'med-memantine',
          ]);
    });

    // ─────────────────────────────────── dosesByDay ──

    test('dosesByDay returns every occurrence on the day with log attached',
        () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-twice',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.twiceDaily,
        timesOfDay: const <TimeOfDay>[
          TimeOfDay(hour: 9, minute: 0),
          TimeOfDay(hour: 21, minute: 0),
        ],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      // Log only the morning dose.
      await repo.upsertDoseLog(DoseLog(
        id: 'log-am',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 30, 9),
        takenAt: DateTime(2026, 5, 30, 9, 3),
        status: DoseStatus.taken,
      ));

      final List<ScheduledDose> day =
          await repo.dosesByDay(DateTime(2026, 5, 30, 14));

      expect(day, hasLength(2));
      expect(day.first.scheduledFor, DateTime(2026, 5, 30, 9));
      expect(day.first.log?.status, DoseStatus.taken);
      expect(day.first.isLogged, isTrue);
      expect(day.last.scheduledFor, DateTime(2026, 5, 30, 21));
      expect(day.last.log, isNull);
      expect(day.last.isLogged, isFalse);
    });

    test('dosesByDay on a day the weekly schedule skips returns empty',
        () async {
      await repo.upsertMedication(donepezil());
      // Mon-only schedule.
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-mon',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.weekly,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 10, minute: 0)],
        daysOfWeek: const <int>{DateTime.monday},
        startsOn: DateTime(2026, 5, 1),
      ));

      // 2026-05-30 is Saturday.
      final List<ScheduledDose> sat =
          await repo.dosesByDay(DateTime(2026, 5, 30));
      expect(sat, isEmpty);

      // 2026-06-01 is Monday.
      final List<ScheduledDose> mon =
          await repo.dosesByDay(DateTime(2026, 6, 1));
      expect(mon, hasLength(1));
      expect(mon.single.scheduledFor, DateTime(2026, 6, 1, 10));
    });

    test('dosesByDay returns empty when no medications exist', () async {
      expect(
          await repo.dosesByDay(DateTime(2026, 5, 30)), isEmpty);
    });

    // ─────────────────────────────────── adherenceRate ──

    test('adherenceRate is 1.0 when no medication / no schedules exist',
        () async {
      // Unknown medication.
      expect(
          await repo.adherenceRate(
              forMedication: 'med-ghost',
              window: const Duration(days: 7)),
          1.0);

      // Known medication, no schedule yet.
      await repo.upsertMedication(donepezil());
      expect(
          await repo.adherenceRate(
              forMedication: 'med-donepezil',
              window: const Duration(days: 7)),
          1.0);
    });

    test('adherenceRate counts taken + late in the numerator, missed in the denominator',
        () async {
      await repo.upsertMedication(donepezil());
      // Daily 9am for 7 days back.
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-daily',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));

      // Window ends at clock (2026-05-30 08:00). Last 7 days =
      // 2026-05-23 08:00 → 2026-05-30 08:00. The 9am doses on May 23
      // through May 29 fall inside; May 30 9am is after the window
      // end. That's 7 occurrences total.
      //
      // Log 3 taken, 1 late, 1 missed, 1 skipped — leaves 1 with no
      // log (counts as missed).
      await repo.upsertDoseLog(DoseLog(
        id: 'l1',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 23, 9),
        takenAt: DateTime(2026, 5, 23, 9, 2),
        status: DoseStatus.taken,
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'l2',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 24, 9),
        takenAt: DateTime(2026, 5, 24, 9, 0),
        status: DoseStatus.taken,
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'l3',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 25, 9),
        takenAt: DateTime(2026, 5, 25, 11, 30),
        status: DoseStatus.late,
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'l4',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 26, 9),
        status: DoseStatus.missed,
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'l5',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 27, 9),
        status: DoseStatus.skipped,
      ));
      await repo.upsertDoseLog(DoseLog(
        id: 'l6',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 28, 9),
        takenAt: DateTime(2026, 5, 28, 9, 5),
        status: DoseStatus.taken,
      ));
      // 2026-05-29 9am intentionally has no log → counts as missed.

      final double rate = await repo.adherenceRate(
        forMedication: 'med-donepezil',
        window: const Duration(days: 7),
      );

      // taken/late = 4 (l1, l2, l3, l6). missed = 2 (l4 + unlogged).
      // skipped (l5) excluded. 4 / 6 = 0.666…
      expect(rate, closeTo(4 / 6, 1e-9));
    });

    test('adherenceRate is 1.0 when every in-window dose was skipped',
        () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-skip',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      for (int day = 23; day <= 29; day++) {
        await repo.upsertDoseLog(DoseLog(
          id: 'skip-$day',
          medicationId: 'med-donepezil',
          scheduledFor: DateTime(2026, 5, day, 9),
          status: DoseStatus.skipped,
        ));
      }

      final double rate = await repo.adherenceRate(
        forMedication: 'med-donepezil',
        window: const Duration(days: 7),
      );

      // Every dose was an intentional hold — denominator is 0, so the
      // helper returns 1.0 per its contract.
      expect(rate, 1.0);
    });

    test('adherenceRate ignores logs that fall outside the window',
        () async {
      await repo.upsertMedication(donepezil());
      await repo.upsertSchedule(DoseSchedule(
        id: 'sched-month',
        medicationId: 'med-donepezil',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      // Old missed dose well outside any 7-day window.
      await repo.upsertDoseLog(DoseLog(
        id: 'old-miss',
        medicationId: 'med-donepezil',
        scheduledFor: DateTime(2026, 5, 5, 9),
        status: DoseStatus.missed,
      ));
      // Every dose in the last 7 days was taken.
      for (int day = 23; day <= 29; day++) {
        await repo.upsertDoseLog(DoseLog(
          id: 'taken-$day',
          medicationId: 'med-donepezil',
          scheduledFor: DateTime(2026, 5, day, 9),
          takenAt: DateTime(2026, 5, day, 9, 1),
          status: DoseStatus.taken,
        ));
      }

      final double rate = await repo.adherenceRate(
        forMedication: 'med-donepezil',
        window: const Duration(days: 7),
      );

      expect(rate, 1.0);
    });
  });

  group('ScheduledDose value semantics', () {
    test('== / hashCode treat structurally-equal triples as equal', () {
      const Medication med = Medication(
        id: 'm',
        name: 'M',
        dosage: '1',
        route: MedicationRoute.oral,
      );
      final DoseSchedule sched = DoseSchedule(
        id: 's',
        medicationId: 'm',
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 9, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      );
      final DateTime when = DateTime(2026, 5, 30, 9);
      final ScheduledDose a = ScheduledDose(
        medication: med,
        schedule: sched,
        scheduledFor: when,
      );
      final ScheduledDose b = ScheduledDose(
        medication: med,
        schedule: sched,
        scheduledFor: when,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a.isLogged, isFalse);
      expect(a.toString(), contains('M'));
    });
  });
}

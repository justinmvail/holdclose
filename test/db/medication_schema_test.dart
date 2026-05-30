import 'dart:convert';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Medication tracker tables (TASKS.md Phase 12.1)', () {
    late CareblazersDatabase db;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    // ---- Helpers --------------------------------------------------------

    Future<void> insertMedication(Medication med) async {
      await db.into(db.medicationsTable).insert(
            MedicationsTableCompanion.insert(
              id: med.id,
              name: med.name,
              payload: jsonEncode(med.toJson()),
            ),
          );
    }

    Future<void> insertSchedule(DoseSchedule s) async {
      await db.into(db.doseSchedulesTable).insert(
            DoseSchedulesTableCompanion.insert(
              id: s.id,
              medicationId: s.medicationId,
              payload: jsonEncode(s.toJson()),
            ),
          );
    }

    Future<void> insertLog(DoseLog log) async {
      await db.into(db.doseLogsTable).insert(
            DoseLogsTableCompanion.insert(
              id: log.id,
              medicationId: log.medicationId,
              scheduledForMs: log.scheduledFor.millisecondsSinceEpoch,
              payload: jsonEncode(log.toJson()),
            ),
          );
    }

    Medication buildMedication({String id = 'med-001'}) => Medication(
          id: id,
          name: 'Donepezil',
          dosage: '10 mg',
          route: MedicationRoute.oral,
          prescriber: 'Dr. Ortega',
        );

    DoseSchedule buildSchedule({
      required String id,
      required String medicationId,
    }) =>
        DoseSchedule(
          id: id,
          medicationId: medicationId,
          frequencyKind: FrequencyKind.daily,
          timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
          daysOfWeek: const <int>{},
          startsOn: DateTime.utc(2026, 6, 1),
        );

    DoseLog buildLog({
      required String id,
      required String medicationId,
      DateTime? scheduledFor,
      DoseStatus status = DoseStatus.taken,
    }) =>
        DoseLog(
          id: id,
          medicationId: medicationId,
          scheduledFor: scheduledFor ?? DateTime.utc(2026, 6, 1, 8),
          takenAt: status == DoseStatus.taken
              ? DateTime.utc(2026, 6, 1, 8, 5)
              : null,
          status: status,
        );

    // ---- Round-trip via the lifted columns ------------------------------

    test('Medication round-trips through the lifted name column', () async {
      await insertMedication(buildMedication());

      final List<MedicationsTableData> rows =
          await db.select(db.medicationsTable).get();
      expect(rows, hasLength(1));
      expect(rows.single.name, 'Donepezil');

      final Medication parsed = Medication.fromJson(
        jsonDecode(rows.single.payload) as Map<String, dynamic>,
      );
      expect(parsed, equals(buildMedication()));
    });

    test('DoseLog round-trips with scheduledForMs lifted out', () async {
      await insertMedication(buildMedication());
      final DoseLog log = buildLog(id: 'log-1', medicationId: 'med-001');
      await insertLog(log);

      final List<DoseLogsTableData> rows =
          await db.select(db.doseLogsTable).get();
      expect(rows, hasLength(1));
      expect(rows.single.scheduledForMs,
          log.scheduledFor.millisecondsSinceEpoch);
      final DoseLog parsed = DoseLog.fromJson(
        jsonDecode(rows.single.payload) as Map<String, dynamic>,
      );
      expect(parsed, equals(log));
    });

    // ---- Cascade-delete invariants (the task acceptance) ----------------

    test(
        'deleting a Medication cascades through its schedules and logs '
        '— zero orphans survive', () async {
      await insertMedication(buildMedication(id: 'will-die'));
      await insertMedication(buildMedication(id: 'will-live'));

      // Two schedules + three logs on the doomed med, one of each on the
      // survivor.
      await insertSchedule(
          buildSchedule(id: 'sched-doomed-1', medicationId: 'will-die'));
      await insertSchedule(
          buildSchedule(id: 'sched-doomed-2', medicationId: 'will-die'));
      for (int i = 0; i < 3; i++) {
        await insertLog(buildLog(
          id: 'log-doomed-$i',
          medicationId: 'will-die',
          scheduledFor: DateTime.utc(2026, 6, 1, 8 + i),
        ));
      }

      await insertSchedule(
          buildSchedule(id: 'sched-survivor', medicationId: 'will-live'));
      await insertLog(
          buildLog(id: 'log-survivor', medicationId: 'will-live'));

      // Sanity: rows wired to their meds.
      expect(await db.select(db.doseSchedulesTable).get(), hasLength(3));
      expect(await db.select(db.doseLogsTable).get(), hasLength(4));

      await (db.delete(db.medicationsTable)
            ..where((t) => t.id.equals('will-die')))
          .go();

      // The medication row is gone.
      final List<MedicationsTableData> meds =
          await db.select(db.medicationsTable).get();
      expect(meds.map((MedicationsTableData r) => r.id).toList(),
          <String>['will-live']);

      // Its schedules cascaded — only the survivor's remains.
      final List<DoseSchedulesTableData> schedules =
          await db.select(db.doseSchedulesTable).get();
      expect(schedules.map((DoseSchedulesTableData r) => r.id).toList(),
          <String>['sched-survivor']);

      // Its logs cascaded — only the survivor's remains.
      final List<DoseLogsTableData> logs =
          await db.select(db.doseLogsTable).get();
      expect(logs.map((DoseLogsTableData r) => r.id).toList(),
          <String>['log-survivor']);

      // And cross-check the orphan count via direct scan, so a stale
      // ORDER BY can't hide a stuck row.
      final int orphanSchedules = schedules
          .where((DoseSchedulesTableData r) => r.medicationId == 'will-die')
          .length;
      final int orphanLogs = logs
          .where((DoseLogsTableData r) => r.medicationId == 'will-die')
          .length;
      expect(orphanSchedules, 0,
          reason: 'ON DELETE CASCADE must remove every schedule row');
      expect(orphanLogs, 0,
          reason: 'ON DELETE CASCADE must remove every dose-log row');
    });

    test('FK pragma is on — insert with an unknown medicationId fails',
        () async {
      // The cascade test above only proves the FK action fires; this one
      // pins that the constraint is even being enforced. Without
      // `PRAGMA foreign_keys = ON`, the insert would silently succeed.
      expect(
        () => insertSchedule(buildSchedule(
            id: 'orphan-sched', medicationId: 'never-existed')),
        throwsA(isA<Exception>()),
      );
      expect(
        () => insertLog(
            buildLog(id: 'orphan-log', medicationId: 'never-existed')),
        throwsA(isA<Exception>()),
      );
    });

    // ---- wipeAll() includes the new tables (Phase 12.1) -----------------

    test('wipeAll() truncates medications + schedules + logs', () async {
      await insertMedication(buildMedication());
      await insertSchedule(
          buildSchedule(id: 'sched-1', medicationId: 'med-001'));
      await insertLog(buildLog(id: 'log-1', medicationId: 'med-001'));

      await db.wipeAll();

      expect(await db.select(db.medicationsTable).get(), isEmpty);
      expect(await db.select(db.doseSchedulesTable).get(), isEmpty);
      expect(await db.select(db.doseLogsTable).get(), isEmpty);
    });
  });
}

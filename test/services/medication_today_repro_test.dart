import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

/// Repro for the alpha bug report "Medication not showing up in today's
/// doses" (Judd, 2026-06-05): a med created today with Morning + Evening
/// windows did not appear under Today's doses. Mirrors exactly what
/// `medication_form_screen.dart` writes.
void main() {
  late HoldcloseDatabase db;
  late MedicationRepository repo;

  // "Now" = mid-afternoon today, the moment Judd added the med.
  final DateTime now = DateTime(2026, 6, 5, 17, 14);
  const String pid = 'demo-patient-mary';

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
    repo = MedicationRepository(db, clock: () => now);
  });
  tearDown(() async => db.close());

  test('med created today (Morning + Evening) appears in dosesByDay(today)',
      () async {
    await repo.upsertMedication(const Medication(
      id: 'med-ibu',
      name: 'Ibuprofen',
      dosage: '400 mg',
      route: MedicationRoute.oral,
    ));
    await repo.upsertWindow(const DoseWindow(
      id: 'win-morning',
      patientId: pid,
      label: 'Morning',
      anchorTime: TimeOfDay(hour: 8, minute: 0),
      sortOrder: 0,
    ));
    await repo.upsertWindow(const DoseWindow(
      id: 'win-evening',
      patientId: pid,
      label: 'Evening',
      anchorTime: TimeOfDay(hour: 19, minute: 0),
      sortOrder: 2,
    ));

    // The form sets startsOn to midnight of "today".
    final DateTime startsOn = DateTime(now.year, now.month, now.day);
    await repo.upsertEntry(MedicationWindowEntry(
      id: 'e-morning',
      medicationId: 'med-ibu',
      windowId: 'win-morning',
      daysOfWeek: const <int>{},
      startsOn: startsOn,
    ));
    await repo.upsertEntry(MedicationWindowEntry(
      id: 'e-evening',
      medicationId: 'med-ibu',
      windowId: 'win-evening',
      daysOfWeek: const <int>{},
      startsOn: startsOn,
    ));

    final List<ScheduledDose> doses =
        await repo.dosesByDay(now, patientId: pid);

    expect(
      doses.map((ScheduledDose d) => d.window.label).toList(),
      containsAll(<String>['Morning', 'Evening']),
      reason: 'a med created today must show up in today\'s doses',
    );
    expect(doses, hasLength(2));
  });
}

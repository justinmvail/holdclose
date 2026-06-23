import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/active_patient_provider.dart';
import 'package:holdclose/screens/medication/dose_log_screen.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Confirms bug #3 ("Medication not showing up in today's doses", Judd):
/// `dosesTodayProvider`, kept alive by a Home card, serves a STALE empty
/// list after a med is added — until something invalidates it.
void main() {
  final DateTime now = DateTime(2026, 6, 5, 17, 14);
  const String pid = 'demo-patient-mary';

  Future<void> addTodaysMed(MedicationRepository repo) async {
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
    await repo.upsertEntry(MedicationWindowEntry(
      id: 'e-morning',
      medicationId: 'med-ibu',
      windowId: 'win-morning',
      daysOfWeek: const <int>{},
      startsOn: DateTime(now.year, now.month, now.day),
    ));
  }

  test('dosesToday goes stale once kept alive, and invalidation refreshes it',
      () async {
    final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final MedicationRepository repo =
        MedicationRepository(db, clock: () => now);

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        doseLogClockProvider.overrideWithValue(() => now),
        activePatientIdProvider.overrideWith((Ref ref) async => pid),
      ],
    );
    addTearDown(container.dispose);

    // Keep dosesToday alive the way Home's catch-me-up card does.
    container.listen(dosesTodayProvider, (_, __) {});
    expect(await container.read(dosesTodayProvider.future), isEmpty);

    // Caregiver adds a med — exactly the reported flow.
    await addTodaysMed(repo);

    // BUG: without invalidating dosesToday, the kept-alive provider still
    // serves the pre-add empty list.
    expect(await container.read(dosesTodayProvider.future), isEmpty,
        reason: 'documents the stale-cache bug');

    // The fix: invalidating dosesToday surfaces the new dose.
    container.invalidate(dosesTodayProvider);
    final List<ScheduledDose> after =
        await container.read(dosesTodayProvider.future);
    expect(after, hasLength(1));
    expect(after.first.medication.name, 'Ibuprofen');
  });
}

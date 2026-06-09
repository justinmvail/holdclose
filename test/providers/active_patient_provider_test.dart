import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/providers/active_patient_provider.dart';
import 'package:careblazers/providers/care_events_provider.dart'
    show fallbackPatientId;
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medication/dose_window_list_screen.dart'
    show doseWindowListProvider;
import 'package:careblazers/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Coverage for the multi-patient active-patient providers (Issue #6):
/// the id defaults to the demo fallback, tracks the stored active
/// selection, and — crucially — flows into a real patient-scoped query
/// (the dose-window list) so switching the active loved one changes which
/// patient's data a downstream provider returns.

Patient _patient(String id, String name) => Patient(
      id: id,
      name: name,
      age: 70,
      diagnosis: 'Dementia',
      diagnosedAt: DateTime.utc(2022, 1, 1),
      medications: const <CrisisMedication>[],
      allergies: const <String>[],
      calms: const <String>[],
      escalates: const <String>[],
      primaryCaregiver: const Contact(name: 'Sam', phone: '555'),
      healthcarePOA: const Contact(name: 'Sam', phone: '555'),
      advanceDirective:
          const AdvanceDirectiveStatus(onFileAt: 'Not on file', dnr: false),
    );

DoseWindow _window(String id, String patientId, String label) => DoseWindow(
      id: id,
      patientId: patientId,
      label: label,
      anchorTime: const TimeOfDay(hour: 8, minute: 0),
      sortOrder: 0,
    );

void main() {
  group('activePatientIdProvider', () {
    test('falls back to the demo id when no patient is on file', () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageBackendProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);

      // No patient → the literal fallback, exactly as the old const did,
      // so callers that thread this still query 'demo-patient-mary'.
      expect(await container.read(activePatientIdProvider.future),
          fallbackPatientId);
    });

    test('resolves the sole patient id, then tracks an explicit switch',
        () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      await storage.upsertPatient(_patient('p-mary', 'Mary'));
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageBackendProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);

      // Single patient → that id (no active id set yet).
      expect(await container.read(activePatientIdProvider.future), 'p-mary');

      // Add a second + switch active; invalidate so the provider re-reads.
      await storage.upsertPatient(_patient('p-frank', 'Frank'));
      await storage.setActivePatientId('p-frank');
      container.invalidate(activePatientProvider);
      container.invalidate(activePatientIdProvider);

      expect(await container.read(activePatientIdProvider.future), 'p-frank');
      expect((await container.read(activePatientProvider.future))!.id,
          'p-frank');
    });
  });

  group('active id flows into a patient-scoped query', () {
    test(
      'switching the active patient changes which windows doseWindowList '
      'returns',
      () async {
        // One shared DB holding windows for two different patients.
        final CareblazersDatabase db =
            CareblazersDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final MedicationRepository repo = MedicationRepository(db);
        await repo.upsertWindow(_window('w-mary', 'p-mary', 'Mary Morning'));
        await repo.upsertWindow(_window('w-frank', 'p-frank', 'Frank Morning'));

        final InMemoryStorageProvider storage = InMemoryStorageProvider();
        addTearDown(storage.dispose);
        await storage.upsertPatient(_patient('p-mary', 'Mary'));
        await storage.upsertPatient(_patient('p-frank', 'Frank'));
        await storage.setActivePatientId('p-mary');

        final ProviderContainer container = ProviderContainer(
          overrides: <Override>[
            storageBackendProvider.overrideWithValue(storage),
            medicationRepositoryBackendProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(container.dispose);

        // Active = Mary → only Mary's window.
        final List<DoseWindow> maryWindows =
            await container.read(doseWindowListProvider.future);
        expect(maryWindows.map((DoseWindow w) => w.id), <String>['w-mary']);

        // Switch active to Frank, invalidate the active providers + the
        // list → it now returns Frank's window. This is the end-to-end
        // proof the active id threads into the patient query.
        await storage.setActivePatientId('p-frank');
        container.invalidate(activePatientProvider);
        container.invalidate(activePatientIdProvider);
        container.invalidate(doseWindowListProvider);

        final List<DoseWindow> frankWindows =
            await container.read(doseWindowListProvider.future);
        expect(frankWindows.map((DoseWindow w) => w.id), <String>['w-frank']);
      },
    );
  });
}

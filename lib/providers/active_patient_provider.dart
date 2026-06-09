import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/patient.dart';
import 'care_events_provider.dart' show fallbackPatientId;
import 'storage_provider.dart';

part 'active_patient_provider.g.dart';

/// The loved one the app is currently centred on (multi-patient, Issue
/// #6).
///
/// Resolves [StorageProvider.getPatient], which itself returns the row
/// whose id [StorageProvider.getActivePatientId] points at — falling back
/// to the sole / first patient when no active id has been chosen. So with
/// exactly one loved one on file (the v1 demo's Mary) this is just "the
/// patient", unchanged; with several it tracks the caregiver's selection.
///
/// `keepAlive` so the resolved patient survives the screen rebuilds a tab
/// switch triggers. The "Loved ones" manager invalidates this (and
/// [activePatientIdProvider]) after a switch / add so the whole app
/// re-reads.
@Riverpod(keepAlive: true)
Future<Patient?> activePatient(Ref ref) async {
  final StorageProvider storage = ref.watch(storageProvider);
  return storage.getPatient();
}

/// The id of the active loved one, defaulting to [fallbackPatientId]
/// ('demo-patient-mary') as a last-resort fallback.
///
/// Threaded into the patient-scoped queries that previously hard-coded
/// the demo id — [MedicationRepository.windowsForPatient] /
/// `dosesInWindow` / `dosesByDay` / `adherenceRate` and the medication +
/// dose-window list screens — so they follow the active patient instead
/// of a constant.
///
/// The fallback is load-bearing for backward compatibility: when no
/// patient is on file yet (a fresh real-mode install, or a widget test
/// that seeds medications but no [Patient]) callers still query
/// 'demo-patient-mary', exactly as the old const did. Resolution errors
/// (e.g. storage unavailable in a unit test that never overrode it) also
/// collapse to the fallback rather than surfacing.
@Riverpod(keepAlive: true)
Future<String> activePatientId(Ref ref) async {
  try {
    final Patient? patient = await ref.watch(activePatientProvider.future);
    final String id = patient?.id ?? '';
    return id.isEmpty ? fallbackPatientId : id;
  } catch (_) {
    return fallbackPatientId;
  }
}

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/medication.dart';
import '../screens/medical/emergency_card_screen.dart'
    show EmergencyCardView, emergencyCardViewProvider;
import '../services/appointment_repository.dart';
import '../services/medication_repository.dart';
import '../services/pdf_exporter.dart';

/// Gathers the loved one's current picture — conditions/allergies (from the
/// emergency card), active medications with their schedules, and upcoming
/// appointments with providers — and renders the shareable care-summary PDF.
/// Null on any failure. autoDispose so it re-gathers each time it's opened.
final careSummaryPdfProvider =
    FutureProvider.autoDispose<Uint8List?>((ref) async {
  try {
    final EmergencyCardView view =
        await ref.watch(emergencyCardViewProvider.future);
    final patient = view.patient;
    if (patient == null) return null; // no loved one on file → nothing to share

    final MedicationRepository medRepo =
        ref.watch(medicationRepositoryBackendProvider);
    final List<Medication> meds = await medRepo.listMedications();
    final List<MedicationWithSchedules> medsWithSchedules =
        <MedicationWithSchedules>[];
    for (final Medication m in meds) {
      final List<MedicationWindowEntry> entries =
          await medRepo.entriesForMedication(m.id);
      final List<({DoseWindow window, MedicationWindowEntry entry})> pairs =
          <({DoseWindow window, MedicationWindowEntry entry})>[];
      for (final MedicationWindowEntry e in entries) {
        final DoseWindow? w = await medRepo.getWindow(e.windowId);
        if (w != null) pairs.add((window: w, entry: e));
      }
      medsWithSchedules
          .add(MedicationWithSchedules(medication: m, windows: pairs));
    }

    final AppointmentRepository apptRepo =
        ref.watch(appointmentRepositoryBackendProvider);
    final List<AppointmentWithProvider> apptsWithProvider =
        <AppointmentWithProvider>[];
    // Types inferred on purpose: the model's `Provider` collides with
    // riverpod's `Provider`, so we never name it here.
    for (final a in await apptRepo.upcoming()) {
      final p = await apptRepo.getProvider(a.providerId);
      apptsWithProvider
          .add(AppointmentWithProvider(appointment: a, provider: p));
    }

    final PdfExporter exporter = ref.watch(pdfExporterProvider);
    return exporter.careSummary(
      patient: patient,
      conditions: view.card?.conditions ?? const <String>[],
      allergies: view.card?.allergies ?? const <String>[],
      medications: medsWithSchedules,
      appointments: apptsWithProvider,
      caregiverName: patient.primaryCaregiver.name,
    );
  } catch (_) {
    return null;
  }
});

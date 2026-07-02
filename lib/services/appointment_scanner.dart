import 'package:dio/dio.dart';

import '../models/appointment.dart' show ProviderRole;
import '../models/appointment_draft.dart';
import '../seed/appointment_extraction_prompt.dart';
import 'document_scan_transport.dart';

/// Reads a photographed appointment card / after-visit slip and proposes an
/// [AppointmentDraft] to pre-fill the appointment form.
///
/// Only proposes — the caregiver reviews and approves on the form (which
/// owns provider find-or-create, date/time, and reminder scheduling) before
/// anything is saved. Behind an interface with a fake (tests/demo) + real
/// (dev shim / prod Worker) impls, sharing transport with the prescription
/// scanner via [document_scan_transport].
abstract class AppointmentScanner {
  /// Extract from the image at [imagePath]; a best-effort draft, or null on
  /// failure (callers open the form blank for manual entry). MUST NOT throw
  /// for an ordinary failure.
  Future<AppointmentDraft?> extractFromImage({required String imagePath});
}

/// Deterministic fake for tests / demo / any `USE_FAKE_LLM=true` build.
class FakeAppointmentScanner implements AppointmentScanner {
  const FakeAppointmentScanner();

  @override
  Future<AppointmentDraft?> extractFromImage({
    required String imagePath,
  }) async {
    return const AppointmentDraft(
      providerName: 'Dr. Berger',
      providerRole: ProviderRole.neurologist,
      providerPhone: '843-767-4500',
      providerAddress: '2135 Ashley Phosphate Rd, North Charleston, SC',
      location: 'Neurology, Suite 200',
      dateText: '6/15/2026',
      timeText: '2:30 PM',
      durationMinutes: 30,
      reason: 'Follow-up visit',
      notes: 'Arrive 15 minutes early; bring the medication list.',
    );
  }
}

/// Dev-mode scanner backed by the local `claude` shim `/extract` route.
class ShimAppointmentScanner implements AppointmentScanner {
  const ShimAppointmentScanner();

  @override
  Future<AppointmentDraft?> extractFromImage({
    required String imagePath,
  }) async {
    final Map<String, dynamic>? map = await shimExtractJson(
      imagePath: imagePath,
      systemPrompt: appointmentExtractionSystemPrompt,
      userPrompt: 'Extract the appointment from this card.',
    );
    return map == null ? null : AppointmentDraft.fromModelJson(map);
  }
}

/// Production scanner routed through the Cloudflare Worker `/extract` route.
/// Dormant until that route ships (only selected when a `FORUM_API_URL` is
/// baked in).
class ApiAppointmentScanner implements AppointmentScanner {
  ApiAppointmentScanner({
    required this.baseUrl,
    required this.tokenLoader,
    this.dio,
  });

  final String baseUrl;
  final Future<String> Function() tokenLoader;
  final Dio? dio;

  @override
  Future<AppointmentDraft?> extractFromImage({
    required String imagePath,
  }) async {
    final Map<String, dynamic>? map = await workerExtractJson(
      imagePath: imagePath,
      systemPrompt: appointmentExtractionSystemPrompt,
      userPrompt: 'Extract the appointment from this card.',
      baseUrl: baseUrl,
      tokenLoader: tokenLoader,
      dio: dio,
    );
    return map == null ? null : AppointmentDraft.fromModelJson(map);
  }
}

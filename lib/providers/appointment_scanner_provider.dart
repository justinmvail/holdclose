import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/appointment_scanner.dart';
import '../services/forum_api_client.dart'
    show forumApiBaseUrl, forumBackendConfigured;
import 'forum_jwt_provider.dart' show forumSessionManagerProvider;
import 'llm_provider.dart' show useFakeLLMEngine;

/// Build-mode-selected [AppointmentScanner] — mirrors the prescription
/// scanner selection: deterministic fake under test/demo, local shim in
/// dev, Worker in a shipped build.
final appointmentScannerProvider = Provider<AppointmentScanner>((ref) {
  if (useFakeLLMEngine) return const FakeAppointmentScanner();
  if (forumBackendConfigured) {
    return ApiAppointmentScanner(
      baseUrl: forumApiBaseUrl,
      tokenLoader: ref.watch(forumSessionManagerProvider).currentToken,
    );
  }
  return const ShimAppointmentScanner();
});

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/forum_api_client.dart'
    show forumApiBaseUrl, forumBackendConfigured;
import '../services/prescription_scanner.dart';
import 'forum_jwt_provider.dart' show forumSessionManagerProvider;
import 'llm_provider.dart' show useFakeLLMEngine;

/// Build-mode-selected [PrescriptionScanner] — mirrors `llmProvider`'s
/// selection so the scan feature is deterministic under test/demo, uses
/// the local shim in dev, and routes through the Worker in a shipped
/// build. Widgets read this and never see the concrete class.
///
/// A plain (non-codegen) provider on purpose: it wires transient service
/// impls with no generated part file, keeping the scan feature free of a
/// build_runner step.
final prescriptionScannerProvider = Provider<PrescriptionScanner>((ref) {
  // Deterministic fake under `flutter test` / USE_FAKE_LLM=true.
  if (useFakeLLMEngine) return const FakePrescriptionScanner();
  // Shipped/alpha build with a real Worker baked in → route through it so
  // the model key stays server-side and the call is behind the quotas.
  if (forumBackendConfigured) {
    return ApiPrescriptionScanner(
      baseUrl: forumApiBaseUrl,
      tokenLoader: ref.watch(forumSessionManagerProvider).currentToken,
    );
  }
  // No backend configured → the local dev shim.
  return const ShimPrescriptionScanner();
});

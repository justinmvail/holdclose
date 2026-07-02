import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/forum_api_client.dart'
    show forumApiBaseUrl, forumBackendConfigured;
import '../services/insurance_card_scanner.dart';
import 'forum_jwt_provider.dart' show forumSessionManagerProvider;
import 'llm_provider.dart' show useFakeLLMEngine;

/// Build-mode-selected [InsuranceCardScanner] — fake under test/demo, shim
/// in dev, Worker in a shipped build.
final insuranceCardScannerProvider = Provider<InsuranceCardScanner>((ref) {
  if (useFakeLLMEngine) return const FakeInsuranceCardScanner();
  if (forumBackendConfigured) {
    return ApiInsuranceCardScanner(
      baseUrl: forumApiBaseUrl,
      tokenLoader: ref.watch(forumSessionManagerProvider).currentToken,
    );
  }
  return const ShimInsuranceCardScanner();
});

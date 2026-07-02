import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/forum_api_client.dart'
    show forumApiBaseUrl, forumBackendConfigured;
import '../services/insurance_appeal_service.dart';
import 'forum_jwt_provider.dart' show forumSessionManagerProvider;
import 'llm_provider.dart' show useFakeLLMEngine;

/// Build-mode-selected [InsuranceAppealService] — deterministic fake under
/// test/demo, local shim in dev, Worker in a shipped build.
final insuranceAppealServiceProvider =
    Provider<InsuranceAppealService>((ref) {
  if (useFakeLLMEngine) return const FakeInsuranceAppealService();
  if (forumBackendConfigured) {
    return ApiInsuranceAppealService(
      baseUrl: forumApiBaseUrl,
      tokenLoader: ref.watch(forumSessionManagerProvider).currentToken,
    );
  }
  return const ShimInsuranceAppealService();
});

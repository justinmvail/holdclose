import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/chat_context_builder.dart';
import '../services/forum_api_client.dart'
    show forumApiBaseUrl, forumBackendConfigured;
import '../services/visit_prep_service.dart';
import 'forum_jwt_provider.dart' show forumSessionManagerProvider;
import 'llm_provider.dart' show useFakeLLMEngine;

/// The loved one's care snapshot rendered to the same text the coach is
/// grounded in — reused by visit-prep so screens (which hold a WidgetRef,
/// not a Ref) can gather it. Empty string on any failure.
final careContextTextProvider = FutureProvider.autoDispose<String>((ref) async {
  try {
    return formatChatContext(await gatherChatContext(ref));
  } catch (_) {
    return '';
  }
});

/// Build-mode-selected [VisitPrepService] — deterministic fake under
/// test/demo, local shim in dev, Worker in a shipped build.
final visitPrepServiceProvider = Provider<VisitPrepService>((ref) {
  if (useFakeLLMEngine) return const FakeVisitPrepService();
  if (forumBackendConfigured) {
    return ApiVisitPrepService(
      baseUrl: forumApiBaseUrl,
      tokenLoader: ref.watch(forumSessionManagerProvider).currentToken,
    );
  }
  return const ShimVisitPrepService();
});

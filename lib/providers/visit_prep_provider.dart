import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/chat_context_builder.dart';
import '../services/forum_api_client.dart'
    show forumApiBaseUrl, forumBackendConfigured;
import '../services/visit_prep_service.dart';
import 'forum_jwt_provider.dart' show forumSessionManagerProvider;
import 'llm_provider.dart' show useFakeLLMEngine;

/// The loved one's care snapshot rendered to the same text the coach is
/// grounded in — reused by visit-prep so screens (which hold a WidgetRef,
/// not a Ref) can gather it. Empty string on any failure — logged, because
/// a silent '' strips the loved one's data out of the AI prompt with no
/// visible symptom. NOTE: never `ref.watch` an autoDispose provider from
/// inside the gather — the one-shot `.future` read pattern disposes such a
/// child mid-await (the fb_1783047813260308 failure in
/// careSummaryPdfProvider); test/providers/visit_prep_provider_test.dart
/// runs this over a cross-isolate DB to catch that regression.
final careContextTextProvider = FutureProvider.autoDispose<String>((ref) async {
  try {
    return formatChatContext(await gatherChatContext(ref));
  } on Object catch (e, st) {
    debugPrint('care context gather failed: $e\n$st');
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

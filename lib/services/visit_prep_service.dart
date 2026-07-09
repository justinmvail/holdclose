import 'package:dio/dio.dart';

import '../seed/visit_prep_prompt.dart';
import 'chat_context_builder.dart' show sanitizeForPrompt;
import 'document_scan_transport.dart';

/// Suggests questions a caregiver could ask at an upcoming doctor visit,
/// grounded in the loved one's care snapshot. Questions only — never advice
/// or diagnosis (Holdclose's medical guardrails); the caregiver picks which
/// to keep. Behind an interface with a fake (tests/demo) + real (shim/Worker)
/// impls, mirroring the scanners.
abstract class VisitPrepService {
  /// Returns 4–6 suggested questions, or null on failure (callers show a
  /// hint and let the caregiver add agenda items by hand). MUST NOT throw.
  Future<List<String>?> suggestQuestions({
    required String careContext,
    String? reason,
  });
}

/// Deterministic fake for tests / demo / any `USE_FAKE_LLM=true` build.
class FakeVisitPrepService implements VisitPrepService {
  const FakeVisitPrepService();

  @override
  Future<List<String>?> suggestQuestions({
    required String careContext,
    String? reason,
  }) async {
    return const <String>[
      'Could any of the current medications be causing the recent drowsiness?',
      'Should we adjust the evening routine given the falls this week?',
      'What symptoms would mean we should call you before the next visit?',
      'Is the latest blood-pressure reading in the range you want?',
    ];
  }
}

/// Dev-mode service backed by the local `claude` shim (`/extract`, text-only).
class ShimVisitPrepService implements VisitPrepService {
  const ShimVisitPrepService();

  @override
  Future<List<String>?> suggestQuestions({
    required String careContext,
    String? reason,
  }) async {
    final Map<String, dynamic>? map = await shimObjectFromPrompt(
      systemPrompt: visitPrepSystemPrompt,
      userPrompt: visitPrepUserPrompt(careContext, reason),
    );
    return questionsFromMap(map);
  }
}

/// Production service routed through the Cloudflare Worker `/extract` route.
/// Dormant until that route ships.
class ApiVisitPrepService implements VisitPrepService {
  ApiVisitPrepService({
    required this.baseUrl,
    required this.tokenLoader,
    this.dio,
  });

  final String baseUrl;
  final Future<String> Function() tokenLoader;
  final Dio? dio;

  @override
  Future<List<String>?> suggestQuestions({
    required String careContext,
    String? reason,
  }) async {
    final Map<String, dynamic>? map = await workerObjectFromPrompt(
      systemPrompt: visitPrepSystemPrompt,
      userPrompt: visitPrepUserPrompt(careContext, reason),
      baseUrl: baseUrl,
      tokenLoader: tokenLoader,
      dio: dio,
    );
    return questionsFromMap(map);
  }
}

/// Assemble the visit-prep user prompt from the care snapshot + reason.
/// Visible for tests.
String visitPrepUserPrompt(String careContext, String? reason) {
  // The reason/notes are free text the caregiver typed — sanitise them
  // (a crafted "［action:…］" or "ignore previous instructions" reaches the
  // model as inert data, never a live tag) and delimit the whole payload so
  // the system prompt scopes its "data, never instructions" rule to it. The
  // care snapshot is already sanitised by the chat context builder.
  final String r = sanitizeForPrompt((reason ?? '').trim());
  final String reasonLine = r.isEmpty ? '' : 'Visit reason / notes: $r\n\n';
  return '<visit_data>\n'
      'Loved one care snapshot:\n$careContext\n\n'
      '$reasonLine'
      '</visit_data>\n\n'
      'Suggest questions to ask at this visit.';
}

/// Pull the string list out of a `{"questions": [...]}` reply; null when the
/// shape is wrong. Visible for tests.
List<String>? questionsFromMap(Map<String, dynamic>? map) {
  if (map == null) return null;
  final dynamic q = map['questions'];
  if (q is List) {
    final List<String> out = <String>[
      for (final dynamic e in q)
        if (e is String && e.trim().isNotEmpty) e.trim(),
    ];
    return out.isEmpty ? null : out;
  }
  return null;
}

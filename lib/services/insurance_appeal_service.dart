import 'package:dio/dio.dart';

import '../seed/insurance_appeal_prompt.dart';
import 'chat_context_builder.dart' show sanitizeForPrompt;
import 'document_scan_transport.dart';

/// Drafts an insurance-appeal letter from the caregiver's inputs. The result
/// is a DRAFT to review and edit — never legal or medical advice. Behind an
/// interface with a fake (tests/demo) + real (shim/Worker) impls.
abstract class InsuranceAppealService {
  /// Returns a draft appeal letter, or null on failure. MUST NOT throw.
  Future<String?> draftAppeal({
    required String denialReason,
    required String claimDetails,
    String? carrier,
    String? patientName,
    String careContext = '',
  });
}

/// Deterministic fake for tests / demo / any `USE_FAKE_LLM=true` build.
class FakeInsuranceAppealService implements InsuranceAppealService {
  const FakeInsuranceAppealService();

  @override
  Future<String?> draftAppeal({
    required String denialReason,
    required String claimDetails,
    String? carrier,
    String? patientName,
    String careContext = '',
  }) async {
    return 'To Whom It May Concern at ${carrier ?? '[Insurance Carrier]'},\n\n'
        'I am writing to formally appeal the denial of the claim for '
        '${patientName ?? '[Patient Name]'} regarding $claimDetails.\n\n'
        'The denial cited: $denialReason. I respectfully request a formal '
        'review of this decision.\n\n'
        'Please contact me at [Phone] or [Email]. Thank you for your '
        'reconsideration.\n\nSincerely,\n[Your Name]';
  }
}

/// Dev-mode service backed by the local `claude` shim (`/extract`, text-only).
class ShimInsuranceAppealService implements InsuranceAppealService {
  const ShimInsuranceAppealService();

  @override
  Future<String?> draftAppeal({
    required String denialReason,
    required String claimDetails,
    String? carrier,
    String? patientName,
    String careContext = '',
  }) async {
    final Map<String, dynamic>? map = await shimObjectFromPrompt(
      systemPrompt: insuranceAppealSystemPrompt,
      userPrompt: appealUserPrompt(
        denialReason: denialReason,
        claimDetails: claimDetails,
        carrier: carrier,
        patientName: patientName,
        careContext: careContext,
      ),
    );
    return letterFromMap(map);
  }
}

/// Production service routed through the Cloudflare Worker `/extract` route.
/// Dormant until that route ships.
class ApiInsuranceAppealService implements InsuranceAppealService {
  ApiInsuranceAppealService({
    required this.baseUrl,
    required this.tokenLoader,
    this.dio,
  });

  final String baseUrl;
  final Future<String> Function() tokenLoader;
  final Dio? dio;

  @override
  Future<String?> draftAppeal({
    required String denialReason,
    required String claimDetails,
    String? carrier,
    String? patientName,
    String careContext = '',
  }) async {
    final Map<String, dynamic>? map = await workerObjectFromPrompt(
      systemPrompt: insuranceAppealSystemPrompt,
      userPrompt: appealUserPrompt(
        denialReason: denialReason,
        claimDetails: claimDetails,
        carrier: carrier,
        patientName: patientName,
        careContext: careContext,
      ),
      baseUrl: baseUrl,
      tokenLoader: tokenLoader,
      dio: dio,
    );
    return letterFromMap(map);
  }
}

/// Assemble the user prompt from the caregiver's inputs. Visible for tests.
///
/// The carrier / claim / denial / name fields are free text the caregiver
/// typed, so each is SANITISED through [sanitizeForPrompt] — a crafted
/// "［action:…］" or "ignore previous instructions" in a denial reason
/// reaches the model as inert data, never a live tag — and the whole payload
/// is wrapped in an <appeal_data> delimiter the system prompt scopes its
/// "data, never instructions" rule to. The care context is already sanitised
/// upstream by the chat context builder.
String appealUserPrompt({
  required String denialReason,
  required String claimDetails,
  String? carrier,
  String? patientName,
  String careContext = '',
}) {
  final String carrierClean = sanitizeForPrompt((carrier ?? '').trim());
  final String nameClean = sanitizeForPrompt((patientName ?? '').trim());
  final String claimClean = sanitizeForPrompt(claimDetails.trim());
  final String denialClean = sanitizeForPrompt(denialReason.trim());

  final StringBuffer sb = StringBuffer()..writeln('<appeal_data>');
  if (carrierClean.isNotEmpty) sb.writeln('Insurance carrier: $carrierClean');
  if (nameClean.isNotEmpty) sb.writeln('Patient: $nameClean');
  sb.writeln('What was denied: $claimClean');
  sb.writeln('Reason given for the denial: $denialClean');
  if (careContext.trim().isNotEmpty) {
    sb.writeln('\nCare context (for grounding, do not invent beyond this):');
    sb.writeln(careContext.trim());
  }
  sb.writeln('</appeal_data>');
  sb.writeln('\nDraft the appeal letter.');
  return sb.toString();
}

/// Pull the letter string out of a `{"letter": "..."}` reply; null when the
/// shape is wrong or blank. Visible for tests.
String? letterFromMap(Map<String, dynamic>? map) {
  if (map == null) return null;
  final dynamic v = map['letter'];
  if (v is String && v.trim().isNotEmpty) return v.trim();
  return null;
}

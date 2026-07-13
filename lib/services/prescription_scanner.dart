import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../models/medication.dart';
import '../models/medication_draft.dart';
import '../providers/llm_provider.dart'
    show buildShimDio, shimAuthHeaders, shimBaseUrl;
import '../seed/prescription_extraction_prompt.dart';
import 'document_scan_transport.dart' show scanJsonOnlyInstruction;
import 'forum_api_client.dart' show forumApiVersionPrefix;

/// Reads a photographed prescription label / medical document and
/// proposes a structured [MedicationDraft] for the caregiver to review.
///
/// The scanner ONLY proposes — it never writes. The caregiver approves
/// (and edits) on the import-review screen before a real [Medication] is
/// saved. That human-in-the-loop gate is a hard product invariant (and
/// the Caregiver-AI-Principle-2 story for the ACL packet).
///
/// Behind an interface with a fake (tests / demo) and real (dev shim /
/// prod Worker) impls, matching the app's "every backend has a fake" rule
/// and the vendor-invisibility guardrail.
abstract class PrescriptionScanner {
  /// Extract from the image at [imagePath]. Returns a best-effort draft,
  /// or null when extraction fails (unreadable image, transport error).
  /// Callers fall back to opening the review screen empty for manual
  /// entry, so this MUST NOT throw for an ordinary failure.
  Future<MedicationDraft?> extractFromImage({required String imagePath});
}

/// Deterministic fake used under `flutter test`, the demo tour, and any
/// `USE_FAKE_LLM=true` build. Ignores the image entirely and returns a
/// canned draft so the whole scan → review → approve pipeline is
/// exercised without touching a model or the camera. Mirrors the seeded
/// post-stroke persona's regimen.
class FakePrescriptionScanner implements PrescriptionScanner {
  const FakePrescriptionScanner();

  @override
  Future<MedicationDraft?> extractFromImage({
    required String imagePath,
  }) async {
    return const MedicationDraft(
      name: 'Lisinopril',
      dosage: '10 mg',
      route: MedicationRoute.oral,
      prescriber: 'Dr. Alvarez',
      notes: 'Take one tablet by mouth once daily.',
      rxNumber: '1687749',
      quantity: '30',
      refills: '3',
      pharmacyName: 'CVS Pharmacy',
      pharmacyPhone: '843-767-4500',
      dateFilled: '12/3/21',
      discardAfter: '12/3/22',
    );
  }
}

/// Dev-mode scanner backed by the local `claude` shim
/// (`tools/claude_shim.py`, `/extract` route). Reads the image bytes,
/// base64-encodes them, and POSTs `{system, user, image_base64}`; the
/// shim runs a one-shot vision completion and returns `{"text": "..."}`
/// which we parse into a [MedicationDraft].
class ShimPrescriptionScanner implements PrescriptionScanner {
  const ShimPrescriptionScanner({Dio? dio, String? endpoint})
      : _injectedDio = dio,
        _endpoint = endpoint;

  final Dio? _injectedDio;
  final String? _endpoint;

  /// The shim's `/extract` endpoint, built from [shimBaseUrl] (override
  /// only for integration tests that pin a different port).
  String get endpoint => _endpoint ?? '$shimBaseUrl/extract';

  @override
  Future<MedicationDraft?> extractFromImage({
    required String imagePath,
  }) async {
    final String? base64Image = await _readAsBase64(imagePath);
    if (base64Image == null) return null;

    final Dio dio = _injectedDio ?? buildShimDio();
    try {
      final Response<dynamic> resp = await dio.post<dynamic>(
        endpoint,
        data: <String, dynamic>{
          'system': prescriptionExtractionSystemPrompt,
          'user': 'Extract the medication from this label.$scanJsonOnlyInstruction',
          'image_base64': base64Image,
        },
        options: Options(
          contentType: Headers.jsonContentType,
          headers: shimAuthHeaders(),
        ),
      );
      return draftFromResponseBody(resp.data);
    } catch (_) {
      // Transport error, timeout, shim down — degrade to manual entry.
      return null;
    }
  }
}

/// Production scanner routed through the Cloudflare Worker so the model
/// key stays server-side and the call sits behind the same quotas the
/// coach uses. POSTs `{system, user, image_base64}` to the Worker's
/// `/extract` route with a bearer session token.
///
/// NOTE: the matching Worker `/extract` route is not deployed yet, so
/// this impl is dormant in current builds (it's only selected when a
/// `FORUM_API_URL` is baked in). Wired now so the prod path is a route
/// addition, not an app change.
class ApiPrescriptionScanner implements PrescriptionScanner {
  ApiPrescriptionScanner({
    required this.baseUrl,
    required this.tokenLoader,
    Dio? dio,
  }) : _injectedDio = dio;

  final String baseUrl;
  final Future<String> Function() tokenLoader;
  final Dio? _injectedDio;

  String get _endpoint {
    final String trimmed =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$trimmed$forumApiVersionPrefix/extract';
  }

  @override
  Future<MedicationDraft?> extractFromImage({
    required String imagePath,
  }) async {
    final String? base64Image = await _readAsBase64(imagePath);
    if (base64Image == null) return null;

    final String token;
    try {
      token = await tokenLoader();
    } catch (_) {
      return null;
    }

    final Dio dio = _injectedDio ?? buildShimDio();
    try {
      final Response<dynamic> resp = await dio.post<dynamic>(
        _endpoint,
        data: <String, dynamic>{
          'system': prescriptionExtractionSystemPrompt,
          'user': 'Extract the medication from this label.$scanJsonOnlyInstruction',
          'image_base64': base64Image,
        },
        options: Options(
          contentType: Headers.jsonContentType,
          headers: <String, String>{'Authorization': 'Bearer $token'},
        ),
      );
      return draftFromResponseBody(resp.data);
    } catch (_) {
      return null;
    }
  }
}

/// Read a file's bytes and base64-encode them; null on any failure (the
/// fake-capture path hands back an asset path that isn't a real file, so
/// a failed read simply means "no extraction" → manual entry).
Future<String?> _readAsBase64(String path) async {
  try {
    final List<int> bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return null;
    return base64Encode(bytes);
  } catch (_) {
    return null;
  }
}

/// Turn a shim/Worker response body into a draft. Accepts either a
/// decoded `{"text": "..."}` map or a raw string body, finds the first
/// JSON object in the reply text, and parses it. Null when nothing
/// usable is present. Visible for unit tests.
MedicationDraft? draftFromResponseBody(dynamic data) {
  if (data is Map && data['text'] is String) {
    return draftFromReplyText(data['text'] as String);
  }
  if (data is String) {
    return draftFromReplyText(data);
  }
  return null;
}

/// Extract the first `{...}` JSON object from the model's reply text and
/// parse it into a [MedicationDraft]. Tolerant of surrounding prose or
/// code fences the model may add despite the prompt. Null when no object
/// is present or it doesn't parse. Visible for unit tests.
MedicationDraft? draftFromReplyText(String text) {
  final int start = text.indexOf('{');
  final int end = text.lastIndexOf('}');
  if (start == -1 || end == -1 || end <= start) return null;
  try {
    final dynamic obj = json.decode(text.substring(start, end + 1));
    if (obj is Map<String, dynamic>) {
      return MedicationDraft.fromModelJson(obj);
    }
  } catch (_) {
    // Not valid JSON — fall through to null (manual entry).
  }
  return null;
}

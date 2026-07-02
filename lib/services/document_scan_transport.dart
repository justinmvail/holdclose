import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../providers/llm_provider.dart'
    show buildShimDio, shimAuthHeaders, shimBaseUrl;
import 'forum_api_client.dart' show forumApiVersionPrefix;

/// Shared, entity-agnostic transport for the AI document-scan features
/// (prescription labels, appointment cards, …). Every scanner reads an
/// image, POSTs `{system, user, image_base64}` to the `/extract` route
/// (dev shim or prod Worker), and parses the model's reply into a JSON
/// map; only the system prompt and the draft model differ per entity.
///
/// Everything here is best-effort and NEVER throws for an ordinary
/// failure — a scan that can't be read degrades to null so the caller can
/// fall back to manual entry.

/// Read a file's bytes and base64-encode them; null on any failure (an
/// asset path from the fake-capture path isn't a real file, so a failed
/// read simply means "no extraction").
Future<String?> readImageAsBase64(String path) async {
  try {
    final List<int> bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return null;
    return base64Encode(bytes);
  } catch (_) {
    return null;
  }
}

/// Find the first `{...}` JSON object in the model's reply text and decode
/// it to a map. Tolerant of surrounding prose / code fences. Null when no
/// object is present or it doesn't parse.
Map<String, dynamic>? jsonMapFromText(String text) {
  final int start = text.indexOf('{');
  final int end = text.lastIndexOf('}');
  if (start == -1 || end == -1 || end <= start) return null;
  try {
    final dynamic obj = json.decode(text.substring(start, end + 1));
    if (obj is Map<String, dynamic>) return obj;
  } catch (_) {
    // Not valid JSON — fall through to null (manual entry).
  }
  return null;
}

/// Turn a shim/Worker response body (`{"text": "..."}` map or a raw
/// string) into the extracted JSON map. Null for an error/unexpected body.
Map<String, dynamic>? jsonMapFromResponseBody(dynamic data) {
  if (data is Map && data['text'] is String) {
    return jsonMapFromText(data['text'] as String);
  }
  if (data is String) {
    return jsonMapFromText(data);
  }
  return null;
}

/// Dev path: POST the image + [systemPrompt] to the local shim's
/// `/extract` route and return the parsed JSON map, or null on failure.
Future<Map<String, dynamic>?> shimExtractJson({
  required String imagePath,
  required String systemPrompt,
  required String userPrompt,
  Dio? dio,
  String? endpoint,
}) async {
  final String? base64Image = await readImageAsBase64(imagePath);
  if (base64Image == null) return null;
  final Dio d = dio ?? buildShimDio();
  try {
    final Response<dynamic> resp = await d.post<dynamic>(
      endpoint ?? '$shimBaseUrl/extract',
      data: <String, dynamic>{
        'system': systemPrompt,
        'user': userPrompt,
        'image_base64': base64Image,
      },
      options: Options(
        contentType: Headers.jsonContentType,
        headers: shimAuthHeaders(),
      ),
    );
    return jsonMapFromResponseBody(resp.data);
  } catch (_) {
    return null;
  }
}

/// Prod path: POST the image + [systemPrompt] to the Worker's `/extract`
/// route (bearer session token) and return the parsed JSON map, or null.
/// Dormant until the Worker route ships (only selected when a
/// `FORUM_API_URL` is baked in).
Future<Map<String, dynamic>?> workerExtractJson({
  required String imagePath,
  required String systemPrompt,
  required String userPrompt,
  required String baseUrl,
  required Future<String> Function() tokenLoader,
  Dio? dio,
}) async {
  final String? base64Image = await readImageAsBase64(imagePath);
  if (base64Image == null) return null;
  final String token;
  try {
    token = await tokenLoader();
  } catch (_) {
    return null;
  }
  final String trimmed =
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  final Dio d = dio ?? buildShimDio();
  try {
    final Response<dynamic> resp = await d.post<dynamic>(
      '$trimmed$forumApiVersionPrefix/extract',
      data: <String, dynamic>{
        'system': systemPrompt,
        'user': userPrompt,
        'image_base64': base64Image,
      },
      options: Options(
        contentType: Headers.jsonContentType,
        headers: <String, String>{'Authorization': 'Bearer $token'},
      ),
    );
    return jsonMapFromResponseBody(resp.data);
  } catch (_) {
    return null;
  }
}

import 'package:dio/dio.dart';

import '../models/document.dart' show Insurance;
import '../seed/insurance_card_prompt.dart';
import 'document_scan_transport.dart';

/// Reads a photographed insurance card and proposes an [Insurance] to
/// pre-fill the emergency card's insurance block. Only proposes — the
/// caregiver reviews and saves on the emergency-card edit form. Behind an
/// interface with fake/shim/Worker impls, sharing the scan transport.
abstract class InsuranceCardScanner {
  /// Extract from the image; a best-effort [Insurance], or null on failure
  /// (callers open the edit form for manual entry). MUST NOT throw.
  Future<Insurance?> extractFromImage({required String imagePath});
}

/// Deterministic fake for tests / demo / any `USE_FAKE_LLM=true` build.
class FakeInsuranceCardScanner implements InsuranceCardScanner {
  const FakeInsuranceCardScanner();

  @override
  Future<Insurance?> extractFromImage({required String imagePath}) async {
    return const Insurance(
      carrier: 'BlueCross Blue Shield',
      policyNumber: 'XYZ123456789',
      groupNumber: 'GRP0042',
      phone: '800-555-0000',
    );
  }
}

/// Dev-mode scanner backed by the local `claude` shim `/extract` route.
class ShimInsuranceCardScanner implements InsuranceCardScanner {
  const ShimInsuranceCardScanner();

  @override
  Future<Insurance?> extractFromImage({required String imagePath}) async {
    final Map<String, dynamic>? map = await shimExtractJson(
      imagePath: imagePath,
      systemPrompt: insuranceCardExtractionSystemPrompt,
      userPrompt:
          'Extract the insurance details from this card.$scanJsonOnlyInstruction',
    );
    return insuranceFromMap(map);
  }
}

/// Production scanner routed through the Cloudflare Worker `/extract` route.
/// Dormant until that route ships.
class ApiInsuranceCardScanner implements InsuranceCardScanner {
  ApiInsuranceCardScanner({
    required this.baseUrl,
    required this.tokenLoader,
    this.dio,
  });

  final String baseUrl;
  final Future<String> Function() tokenLoader;
  final Dio? dio;

  @override
  Future<Insurance?> extractFromImage({required String imagePath}) async {
    final Map<String, dynamic>? map = await workerExtractJson(
      imagePath: imagePath,
      systemPrompt: insuranceCardExtractionSystemPrompt,
      userPrompt:
          'Extract the insurance details from this card.$scanJsonOnlyInstruction',
      baseUrl: baseUrl,
      tokenLoader: tokenLoader,
      dio: dio,
    );
    return insuranceFromMap(map);
  }
}

/// Build an [Insurance] from an extraction map; null when nothing usable was
/// read. Missing fields become empty strings (the edit form fills the gaps).
/// Visible for tests.
Insurance? insuranceFromMap(Map<String, dynamic>? map) {
  if (map == null) return null;
  String? str(Object? v) {
    if (v is String) {
      final String t = v.trim();
      return t.isEmpty ? null : t;
    }
    return null;
  }

  final String? carrier = str(map['carrier']) ?? str(map['name']);
  final String? policy = str(map['policyNumber']) ??
      str(map['policy_number']) ??
      str(map['memberId']) ??
      str(map['member_id']);
  final String? group = str(map['groupNumber']) ?? str(map['group_number']);
  final String? phone = str(map['phone']) ?? str(map['pharmacyPhone']);

  if (carrier == null && policy == null && group == null && phone == null) {
    return null;
  }
  return Insurance(
    carrier: carrier ?? '',
    policyNumber: policy ?? '',
    groupNumber: group ?? '',
    phone: phone,
  );
}

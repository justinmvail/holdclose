// JsonKey on a freezed factory parameter is the documented pattern for
// renaming a JSON field; the analyzer's `invalid_annotation_target`
// warning is a known false-positive for this combination.
// ignore_for_file: invalid_annotation_target

import 'package:freezed_annotation/freezed_annotation.dart';

part 'decoder_result.freezed.dart';
part 'decoder_result.g.dart';

/// The parsed LLM output for a single decoder call (BUILD_SPEC.md §7.3).
///
/// Shape mirrors the JSON schema in the system prompt
/// (BUILD_SPEC.md §7.1): 2–3 [say] entries the caregiver can read
/// aloud, 1–2 environmental [tweak] entries, 1–2 [dontSay] warnings.
/// [generatedAt] is the local clock at parse-done time and is used by
/// the journal grouping (Today / Yesterday / older).
@freezed
abstract class DecoderResult with _$DecoderResult {
  const factory DecoderResult({
    required List<String> say,
    required List<String> tweak,
    @JsonKey(name: 'dont_say') required List<String> dontSay,
    required DateTime generatedAt,
  }) = _DecoderResult;

  factory DecoderResult.fromJson(Map<String, dynamic> json) =>
      _$DecoderResultFromJson(json);
}

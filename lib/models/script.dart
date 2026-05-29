import 'package:freezed_annotation/freezed_annotation.dart';

part 'script.freezed.dart';
part 'script.g.dart';

/// One "Try saying:" line on the decoder result screen
/// (BUILD_SPEC.md §5.4 + §7.3).
///
/// The current v1 LLM output is a plain `List<String>` of [text] (see
/// [DecoderResult.say]). [audioPath] is reserved for future use:
/// Phase 8 polish will let Dr. Natali record audio clips per canonical
/// script and attach them here so playback uses her voice instead of
/// OS TTS. Until then it's always null and the screen falls back to
/// `flutter_tts`.
@freezed
abstract class Script with _$Script {
  const factory Script({
    required String text,
    String? audioPath,
  }) = _Script;

  factory Script.fromJson(Map<String, dynamic> json) =>
      _$ScriptFromJson(json);
}

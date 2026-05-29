import 'package:flutter/services.dart';

import 'tts_provider.dart';

/// Channel name shared with the iOS/Android native bridges
/// (BUILD_SPEC.md Phase 9.2 — `careblazers/tts`).
///
/// Exposed as a top-level const so the platform stubs can match the
/// exact string the Dart side dials. Keep in sync with the
/// FlutterMethodChannel registration in
/// `ios/Runner/AppDelegate.swift` and the MethodChannel registration
/// in `android/.../MainActivity.kt`.
const String bundledTtsChannelName = 'careblazers/tts';

/// On-device neural-TTS backend (BUILD_SPEC.md Phase 9 — Piper voice
/// model running through ONNX Runtime, bundled at ~30 MB).
///
/// This Dart slice is purely the contract: it forwards `speak`,
/// `cancel`, and `availableVoices` over the [bundledTtsChannelName]
/// MethodChannel. The actual ONNX inference + CoreML/NNAPI execution
/// lands in Phases 9.3 (iOS Swift) and 9.4 (Android Kotlin). Until
/// then the native sides return stubs so the Dart wiring + tests
/// exercise end-to-end without producing audio.
///
/// Conforms to [TTSProvider] so the riverpod factory in
/// `tts_provider.dart` can swap it in alongside [OSTTSProvider] and
/// [NoopTTSProvider] without consumers caring which impl they got.
class BundledTTSProvider implements TTSProvider {
  BundledTTSProvider({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(bundledTtsChannelName);

  /// Channel name the iOS/Android bridges must register.
  static const String channelName = bundledTtsChannelName;

  final MethodChannel _channel;

  /// Forwards `{text, voiceId, speed}` to the native bridge as a
  /// single map argument. Returns once the platform call resolves —
  /// callers still get the same "await-to-completion" semantics as
  /// [OSTTSProvider.speak] in production, where the native side won't
  /// resolve until the utterance finishes.
  @override
  Future<void> speak(
    String text, {
    required String voiceId,
    required double speed,
  }) async {
    await _channel.invokeMethod<void>('speak', <String, dynamic>{
      'text': text,
      'voiceId': voiceId,
      'speed': speed,
    });
  }

  @override
  Future<void> cancel() async {
    await _channel.invokeMethod<void>('cancel');
  }

  /// Parses the native side's response into [TTSVoice] records. The
  /// bridge returns `List<Map<String, Object?>>` with keys `id`,
  /// `displayName`, `locale`, and (optional) `gender`. Malformed entries
  /// (missing required keys, non-map entries) are skipped silently so a
  /// single bad voice doesn't poison the picker dropdown.
  @override
  Future<List<TTSVoice>> availableVoices() async {
    final List<dynamic>? raw =
        await _channel.invokeListMethod<dynamic>('availableVoices');
    if (raw == null) return const <TTSVoice>[];
    final List<TTSVoice> out = <TTSVoice>[];
    for (final dynamic entry in raw) {
      if (entry is! Map) continue;
      final String? id = entry['id']?.toString();
      final String? displayName = entry['displayName']?.toString();
      final String? locale = entry['locale']?.toString();
      if (id == null || displayName == null || locale == null) continue;
      final String gender = entry['gender']?.toString() ?? 'unknown';
      out.add(TTSVoice(
        id: id,
        displayName: displayName,
        locale: locale,
        gender: gender,
      ));
    }
    return out;
  }
}

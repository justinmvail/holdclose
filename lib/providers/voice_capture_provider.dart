import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/real_capture.dart';
import 'photo_attacher_provider.dart' show useRealCapture;

part 'voice_capture_provider.g.dart';

/// Speech-to-text capture seam for the multi-kind Add sheet (BUILD_SPEC.md
/// Phase 14.13 — each Add row carries a [VoiceButton] that captures one
/// spoken phrase and forwards the transcript to the destination screen).
///
/// V1's pubspec pins no speech-recognition plugin — adding one would touch
/// BUILD_SPEC.md §1's dependency invariant — so production wires
/// [UnavailableVoiceCapture]: the mic affordance renders, but a real
/// capture resolves to null until a recognizer plugin lands (a later
/// polish item, the same staging the journal voice-note recorder uses in
/// [voiceNoteRecorderProvider]). Phase 14.14 wires the permission-denied /
/// no-transcript path to a clear snackbar.
///
/// Widget tests override this with a stand-in that returns a deterministic
/// transcript so the row's capture→forward wiring is exercised without a
/// live microphone.
abstract class VoiceCapture {
  /// Capture one spoken phrase, resolving to the recognized transcript.
  /// Returns null when nothing usable was captured — silence or (in v1)
  /// no recognizer is wired yet. Callers treat a null/blank result as
  /// "no transcript" and don't navigate.
  ///
  /// [onPartial], when given, is invoked with the best running transcript
  /// as the recognizer hears more words — so a caller can show live,
  /// Siri-style dictation while the caregiver is still speaking. It may
  /// fire zero times (a stand-in recognizer, or a one-shot result). The
  /// final value is still the Future's result.
  ///
  /// Throws [VoiceCapturePermissionDeniedException] when the OS refused
  /// microphone / speech access — distinct from a null result so the
  /// caller can surface a clear "turn the mic on" prompt instead of
  /// failing silently (Phase 14.14).
  Future<String?> capture({void Function(String partial)? onPartial});
}

/// Raised by [VoiceCapture.capture] when microphone / speech-recognition
/// permission was denied. Carried as an exception (rather than a null
/// transcript) so the [VoiceButton] capture flow can tell "the caregiver
/// said nothing" apart from "the mic is blocked" and only show the
/// permission snackbar in the latter case (Phase 14.14).
class VoiceCapturePermissionDeniedException implements Exception {
  const VoiceCapturePermissionDeniedException();

  @override
  String toString() => 'VoiceCapturePermissionDeniedException';
}

/// Production stand-in until a real speech recognizer is bundled
/// (BUILD_SPEC.md §1 pinned-deps invariant). The mic button still renders
/// and is tappable; the capture simply yields nothing.
class UnavailableVoiceCapture implements VoiceCapture {
  const UnavailableVoiceCapture();

  @override
  Future<String?> capture({void Function(String partial)? onPartial}) async =>
      null;
}

/// Pure impl selector — [RealVoiceCapture] when [useReal] is set, else
/// the [UnavailableVoiceCapture] stand-in. Split out from the provider so
/// both branches are unit-testable without recompiling against the
/// `USE_REAL_CAPTURE` dart-define.
VoiceCapture selectVoiceCapture(bool useReal) =>
    useReal ? RealVoiceCapture() : const UnavailableVoiceCapture();

/// Riverpod-wired capture seam. Widgets read this and get whichever impl
/// the build mode picked — the real `speech_to_text` recognizer when the
/// `USE_REAL_CAPTURE` flag is set (see [useRealCapture] in
/// `photo_attacher_provider.dart`), the unavailable stand-in otherwise —
/// or whatever a test overrode.
@Riverpod(keepAlive: true)
VoiceCapture voiceCapture(Ref ref) => selectVoiceCapture(useRealCapture);

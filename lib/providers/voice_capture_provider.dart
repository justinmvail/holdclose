import 'package:riverpod_annotation/riverpod_annotation.dart';

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
  /// Returns null when nothing usable was captured — permission denied,
  /// silence, or (in v1) no recognizer is wired yet. Callers treat a
  /// null/blank result as "no transcript" and don't navigate.
  Future<String?> capture();
}

/// Production stand-in until a real speech recognizer is bundled
/// (BUILD_SPEC.md §1 pinned-deps invariant). The mic button still renders
/// and is tappable; the capture simply yields nothing.
class UnavailableVoiceCapture implements VoiceCapture {
  const UnavailableVoiceCapture();

  @override
  Future<String?> capture() async => null;
}

/// Riverpod-wired capture seam. Widgets read this and get the impl the
/// host overrode (or the no-op default in production).
@Riverpod(keepAlive: true)
VoiceCapture voiceCapture(Ref ref) => const UnavailableVoiceCapture();

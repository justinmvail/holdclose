import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'voice_note_recorder_provider.g.dart';

/// Voice-note capture surface for the journal-entry detail screen
/// (BUILD_SPEC.md §5.6 — "Voice note: 🎙 record button, plays back
/// inline once attached").
///
/// V1 has no real audio plugin baked into pubspec.yaml — adding one
/// touches BUILD_SPEC.md §1's pinned-deps invariant. So this interface
/// is the swappable seam: production wires [NoopVoiceNoteRecorder]
/// (visible UI affordance, no actual capture yet — the seed data ships
/// a silence m4a per BUILD_SPEC.md §9.2 and the journal entry just
/// stores a path string), and widget tests wire a stand-in that
/// records calls + returns deterministic paths.
///
/// When a real recording plugin lands (a v1.1 polish item), only the
/// concrete impl changes — every consumer keeps reading the interface
/// through [voiceNoteRecorderProvider].
abstract class VoiceNoteRecorder {
  /// Begin capture. Resolves when the platform has actually started —
  /// the journal screen flips its mic-button into "recording" state
  /// after the future completes.
  Future<void> start();

  /// Stop capture and return the on-device path of the recorded clip,
  /// or null if the user aborted before any data was written.
  Future<String?> stop();

  /// Whether a capture is currently in flight. Synchronous so the
  /// screen can rebuild its button state without an extra await.
  bool get isRecording;

  /// Play back the clip at [path]. The screen pipes this through
  /// regardless of where the path came from — fresh capture or a
  /// previously-saved entry.
  Future<void> play(String path);

  /// Stop any in-flight playback. Always safe to call.
  Future<void> stopPlayback();
}

/// No-op impl used by production until a real recorder plugin lands
/// (BUILD_SPEC.md §1 pin invariant).
///
/// Mints a deterministic path so the rest of the wiring — persistence,
/// "🔊 chip" affordance on the journal list, golden tests — still
/// exercises the full code path even though the audio file is silence.
class NoopVoiceNoteRecorder implements VoiceNoteRecorder {
  NoopVoiceNoteRecorder();

  bool _recording = false;

  @override
  bool get isRecording => _recording;

  @override
  Future<void> start() async {
    _recording = true;
  }

  @override
  Future<String?> stop() async {
    if (!_recording) return null;
    _recording = false;
    return 'assets/seed/sample-voice-1.m4a';
  }

  @override
  Future<void> play(String path) async {}

  @override
  Future<void> stopPlayback() async {}
}

/// Riverpod-wired recorder. Widgets read this and get the impl the
/// host overrode (or the no-op default in production).
@Riverpod(keepAlive: true)
VoiceNoteRecorder voiceNoteRecorder(Ref ref) => NoopVoiceNoteRecorder();

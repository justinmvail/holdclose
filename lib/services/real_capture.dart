/// Real device-backed capture implementations (#8).
///
/// These satisfy the same three seams the production fakes do
/// ([PhotoAttacher], [VoiceNoteRecorder], [VoiceCapture]) but talk to
/// the OS camera / gallery / microphone via `image_picker`, `record` +
/// `audioplayers`, and `speech_to_text`. They are selected ONLY when the
/// `USE_REAL_CAPTURE` build flag is flipped on (see each provider file);
/// the default build, `flutter test`, and the demo tour keep the
/// Noop/Unavailable fakes, so nothing here is exercised without a
/// physical device + the flag.
///
/// Each method requests its own permission and degrades gracefully:
/// a denied/unavailable photo or voice-note capture resolves to a null
/// path (the screen simply doesn't attach), and a denied speech capture
/// throws [VoiceCapturePermissionDeniedException] so the Add-sheet voice
/// button can show the "turn the mic on" snackbar (matching the
/// [VoiceCapture] contract).
library;

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../providers/photo_attacher_provider.dart';
import '../providers/voice_capture_provider.dart';
import '../providers/voice_note_recorder_provider.dart';

/// `image_picker`-backed [PhotoAttacher].
///
/// Presents the OS image picker (defaults to the photo library so a
/// single tap doesn't force the camera) and returns the picked file's
/// on-device path, or null when the caregiver cancels or the platform
/// denies access. `image_picker` surfaces a permission denial as either
/// a null result or a `PlatformException`; both collapse to "no photo
/// attached" here, since the photo seam has no permission-exception
/// channel (unlike voice).
class RealPhotoAttacher implements PhotoAttacher {
  RealPhotoAttacher({ImagePicker? picker, this.source = ImageSource.gallery})
      : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// Which OS surface to open. Defaults to the photo library; a camera
  /// variant can be wired by constructing with [ImageSource.camera].
  final ImageSource source;

  @override
  Future<String?> pickPhoto() async {
    try {
      final XFile? file = await _picker.pickImage(source: source);
      return file?.path;
    } catch (_) {
      // Cancelled, no camera, or permission denied — the journal entry
      // just keeps no photo. The photo affordance has no separate
      // "denied" path, so a swallowed failure is the graceful outcome.
      return null;
    }
  }
}

/// `record`-backed [VoiceNoteRecorder] with `audioplayers` playback.
///
/// `start()` requests mic permission, mints a unique m4a path under the
/// app documents dir, and begins an AAC capture; `stop()` finalizes the
/// file and returns its path. `play()` / `stopPlayback()` drive a single
/// reused [AudioPlayer]. A denied permission leaves [isRecording] false
/// and makes `stop()` return null, so the journal screen never flips
/// into a fake "recording" state.
class RealVoiceNoteRecorder implements VoiceNoteRecorder {
  RealVoiceNoteRecorder({AudioRecorder? recorder, AudioPlayer? player})
      : _injectedRecorder = recorder,
        _injectedPlayer = player;

  // Plugin handles are created lazily on first use: both the
  // `AudioRecorder` and `AudioPlayer` constructors touch platform
  // channels immediately, so eager construction would crash anywhere
  // without a binding (e.g. the selection unit test). Lazy init keeps
  // construction side-effect-free while still reusing one handle each.
  final AudioRecorder? _injectedRecorder;
  final AudioPlayer? _injectedPlayer;
  AudioRecorder? _lazyRecorder;
  AudioPlayer? _lazyPlayer;

  AudioRecorder get _recorder =>
      _injectedRecorder ?? (_lazyRecorder ??= AudioRecorder());
  AudioPlayer get _player =>
      _injectedPlayer ?? (_lazyPlayer ??= AudioPlayer());

  bool _recording = false;

  @override
  bool get isRecording => _recording;

  @override
  Future<void> start() async {
    final bool granted = await _recorder.hasPermission();
    if (!granted) {
      // Mic blocked — stay un-recording so the screen's button doesn't
      // pretend a capture is in flight.
      _recording = false;
      return;
    }
    final Directory dir = await getApplicationDocumentsDirectory();
    final String path = p.join(
      dir.path,
      'voice-note-${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    _recording = true;
  }

  @override
  Future<String?> stop() async {
    if (!_recording) return null;
    _recording = false;
    return _recorder.stop();
  }

  @override
  Future<void> play(String path) async {
    await _player.stop();
    await _player.play(DeviceFileSource(path));
  }

  @override
  Future<void> stopPlayback() async {
    await _player.stop();
  }
}

/// `speech_to_text`-backed [VoiceCapture].
///
/// Initializes the recognizer once, then listens for a single utterance,
/// resolving to the recognized transcript (or null on silence). When the
/// OS refuses microphone / speech-recognition access, the `initialize()`
/// error listener reports a permanent error and this throws
/// [VoiceCapturePermissionDeniedException] so the [VoiceButton] flow can
/// surface the permission snackbar rather than failing silently.
class RealVoiceCapture implements VoiceCapture {
  RealVoiceCapture({SpeechToText? speech, this.listenFor})
      : _injectedSpeech = speech;

  // Lazy for the same reason as the recorder: keep construction
  // side-effect-free so the selection unit test can build the type
  // without a Flutter binding. The recognizer is created on first
  // capture() and reused (and re-initialized only when needed).
  final SpeechToText? _injectedSpeech;
  SpeechToText? _lazySpeech;
  SpeechToText get _speech =>
      _injectedSpeech ?? (_lazySpeech ??= SpeechToText());

  /// Hard cap on a single listen session. Null lets `speech_to_text`
  /// use its own pause-driven default.
  final Duration? listenFor;

  bool _initialized = false;

  @override
  Future<String?> capture() async {
    bool permissionDenied = false;

    if (!_initialized) {
      _initialized = await _speech.initialize(
        onError: (SpeechRecognitionError error) {
          // The plugin reports a denied mic / unsupported recognizer as
          // a permanent error during init; flag it so we can raise the
          // typed exception below.
          final String msg = error.errorMsg;
          if (error.permanent ||
              msg.contains('permission') ||
              msg.contains('denied') ||
              msg.contains('not-allowed')) {
            permissionDenied = true;
          }
        },
      );
    }

    if (!_initialized || !_speech.isAvailable) {
      if (permissionDenied) {
        throw const VoiceCapturePermissionDeniedException();
      }
      // Recognizer genuinely unavailable on this device — treat as "no
      // transcript" rather than an error (matches the seam contract).
      return null;
    }

    final Completer<String?> completer = Completer<String?>();

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (result.finalResult && !completer.isCompleted) {
          final String words = result.recognizedWords.trim();
          completer.complete(words.isEmpty ? null : words);
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: false,
        cancelOnError: true,
        listenFor: listenFor,
      ),
    );

    // Resolves when the engine emits its final result (the listener
    // above completes the completer). `cancelOnError: true` ends the
    // session on a recognizer error so this can't hang indefinitely.
    return completer.future;
  }
}

import 'package:holdclose/providers/voice_capture_provider.dart';
import 'package:holdclose/services/real_capture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Regression coverage for the center-mic "spinner hangs forever" bug
/// (fb IMG_0725). The widget tests exercise the capture→new-chat wiring
/// with a FAKE [VoiceCapture] that returns instantly, so they can't catch
/// the real recognizer never finalizing. These tests drive
/// [RealVoiceCapture] against a fake [SpeechToText] to prove `capture()`
/// ALWAYS resolves — on a final result, on a stop-status (silence/timeout),
/// and that the pause/listen durations are actually handed to `listen()`
/// (the bug was that they never were, so the iOS session ran forever).
void main() {
  SpeechRecognitionResult result(String words, {required bool isFinal}) =>
      SpeechRecognitionResult.init(
        <SpeechRecognitionWords>[SpeechRecognitionWords(words, null, 1)],
        isFinal ? ResultType.finalResult : ResultType.partial,
      );

  group('RealVoiceCapture.capture()', () {
    test('resolves with the final transcript when a final result arrives',
        () async {
      final _FakeSpeech speech = _FakeSpeech();
      final RealVoiceCapture capture = RealVoiceCapture(speech: speech);

      final Future<String?> pending = capture.capture();
      await Future<void>.delayed(Duration.zero); // let listen() register
      speech.onResult!(result('why is she pacing', isFinal: true));

      expect(await pending, 'why is she pacing');
    });

    test(
        'resolves on a stop-status using the last partial — even when NO '
        'final result ever fires (the actual hang bug)', () async {
      final _FakeSpeech speech = _FakeSpeech();
      final RealVoiceCapture capture = RealVoiceCapture(speech: speech);

      final Future<String?> pending = capture.capture();
      await Future<void>.delayed(Duration.zero);
      // Stream a partial, then the engine stops on silence — no finalResult.
      speech.onResult!(result('take her to the', isFinal: false));
      speech.statusListener!(SpeechToText.doneStatus);

      expect(await pending, 'take her to the');
    });

    test('passes pauseFor + listenFor to listen() so it can never run forever',
        () async {
      final _FakeSpeech speech = _FakeSpeech();
      final RealVoiceCapture capture = RealVoiceCapture(
        speech: speech,
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 2),
      );

      final Future<String?> pending = capture.capture();
      await Future<void>.delayed(Duration.zero);
      // The durations reached the plugin (the original bug left both null).
      expect(speech.lastPauseFor, const Duration(seconds: 2));
      expect(speech.lastListenFor, const Duration(seconds: 20));

      speech.statusListener!(SpeechToText.notListeningStatus);
      await pending; // resolves (empty → null), doesn't hang
    });

    test('a stop with no words resolves to null (no empty thread)', () async {
      final _FakeSpeech speech = _FakeSpeech();
      final RealVoiceCapture capture = RealVoiceCapture(speech: speech);

      final Future<String?> pending = capture.capture();
      await Future<void>.delayed(Duration.zero);
      speech.statusListener!(SpeechToText.doneStatus);

      expect(await pending, isNull);
    });

    test('a permanent permission error during init throws the typed exception',
        () async {
      final _FakeSpeech speech = _FakeSpeech(
        initResult: false,
        permanentErrorOnInit: 'not-allowed',
      );
      final RealVoiceCapture capture = RealVoiceCapture(speech: speech);

      expect(
        capture.capture(),
        throwsA(isA<VoiceCapturePermissionDeniedException>()),
      );
    });

    test('an unavailable recognizer resolves to null, not an error', () async {
      final _FakeSpeech speech = _FakeSpeech(available: false);
      final RealVoiceCapture capture = RealVoiceCapture(speech: speech);

      expect(await capture.capture(), isNull);
    });
  });
}

/// Minimal [SpeechToText] stand-in. `SpeechToText()` is a factory (can't be
/// subclassed), so this `implements` the interface and stubs everything
/// else via [noSuchMethod] — only the four members [RealVoiceCapture]
/// actually touches are real. Records what `listen()` was handed and lets
/// the test drive results + status callbacks deterministically.
class _FakeSpeech implements SpeechToText {
  _FakeSpeech({
    this.available = true,
    this.initResult = true,
    this.permanentErrorOnInit,
  });

  final bool available;
  final bool initResult;
  final String? permanentErrorOnInit;

  @override
  SpeechStatusListener? statusListener;

  SpeechResultListener? onResult;
  Duration? lastPauseFor;
  Duration? lastListenFor;
  bool stopped = false;

  @override
  bool get isAvailable => available;

  @override
  Future<bool> initialize({
    SpeechErrorListener? onError,
    SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = SpeechToText.defaultFinalTimeout,
    List<SpeechConfigOption>? options,
  }) async {
    statusListener = onStatus;
    if (permanentErrorOnInit != null) {
      onError?.call(SpeechRecognitionError(permanentErrorOnInit!, true));
    }
    return initResult;
  }

  @override
  Future<dynamic> listen({
    SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    SpeechSoundLevelChange? onSoundLevelChange,
    dynamic cancelOnError = false,
    dynamic partialResults = true,
    dynamic onDevice = false,
    ListenMode listenMode = ListenMode.confirmation,
    dynamic sampleRate = 0,
    SpeechListenOptions? listenOptions,
  }) async {
    this.onResult = onResult;
    lastListenFor = listenFor;
    lastPauseFor = pauseFor;
  }

  @override
  Future<dynamic> stop() async {
    stopped = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

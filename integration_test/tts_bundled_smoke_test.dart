/// Does the bundled neural voice survive one utterance ON A REAL PHONE?
///
/// This is the ONLY test that can catch the 2026-07-14 crash, and it must be run
/// on a CABLED DEVICE to do it:
///
///   flutter test integration_test/tts_bundled_smoke_test.dart -d <udid>
///
/// The crash was a hard SIGSEGV inside Apple's BNNS convolution kernel, reached
/// through the ONNX CoreML execution provider:
///
///   libBNNS  BNNSFilterApplyBatch
///   Espresso Espresso::BNNSEngine::convolution_kernel::__launch
///   CoreML   -[MLNeuralNetworkEngine executePlan:error:]
///
/// Why nothing else could see it:
///   * `flutter test` is hermetic — the native TTS bridge does not exist there.
///   * The SIMULATOR is useless for this: the CoreML EP was `#if`-compiled OUT
///     of simulator builds, so the sim ran a DIFFERENT inference backend (plain
///     CPU) and passed happily while every real phone segfaulted.
///   * The app never called `speak()` at all until the coach's voice was wired
///     up (2026-07-13), so six weeks of real-device use never touched this code.
///
/// A green run means the process SURVIVED synthesis — that is the whole
/// assertion. A regression here does not fail the test; it kills the runner.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/providers/bundled_tts_provider.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the bundled voice speaks without killing the process',
      (WidgetTester tester) async {
    final BundledTTSProvider tts = BundledTTSProvider();

    // The production call, byte for byte: `voiceId: ''` is what the app passes
    // until a caregiver picks a voice, and it resolves to en_US-amy-medium.
    await tts.speak('Opening the calendar.', voiceId: '', speed: 1.0);
    await tester.pump(const Duration(seconds: 2));

    // Speak again — the ORT session is cached after the first load, so a second
    // utterance exercises the reused-session path the first one cannot.
    await tts.speak('She took her medication this morning.',
        voiceId: '', speed: 1.0);
    await tester.pump(const Duration(seconds: 2));

    await tts.cancel();

    // Reaching this line IS the assertion: synthesis ran twice, and the process
    // is still alive to say so.
    expect(true, isTrue);
  });
}

import 'package:careblazers/providers/voice_capture_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default impl is the unavailable (no-recognizer) stand-in', () {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(voiceCaptureProvider),
      isA<UnavailableVoiceCapture>(),
    );
  });

  test('UnavailableVoiceCapture yields no transcript', () async {
    expect(await const UnavailableVoiceCapture().capture(), isNull);
  });
}

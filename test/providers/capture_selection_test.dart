import 'package:holdclose/providers/photo_attacher_provider.dart';
import 'package:holdclose/providers/voice_capture_provider.dart';
import 'package:holdclose/providers/voice_note_recorder_provider.dart';
import 'package:holdclose/services/real_capture.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the #8 "real capture behind a build flag, fakes by default"
/// contract. The `USE_REAL_CAPTURE` dart-define is a compile-time const
/// (defaults false), so the providers can only be observed in their
/// default state here — those tests pin that the simulator demo +
/// `flutter test` keep the Noop/Unavailable fakes. The real-vs-fake
/// branch is proven through the pure `select…` helpers, which take the
/// flag as a plain argument so both sides are exercisable without a
/// device or a rebuild.
void main() {
  group('build flag default', () {
    test('USE_REAL_CAPTURE defaults to false', () {
      expect(useRealCapture, isFalse);
    });
  });

  group('providers resolve to the fakes by default', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('photoAttacher → NoopPhotoAttacher', () {
      expect(
        container.read(photoAttacherProvider),
        isA<NoopPhotoAttacher>(),
      );
    });

    test('voiceNoteRecorder → NoopVoiceNoteRecorder', () {
      expect(
        container.read(voiceNoteRecorderProvider),
        isA<NoopVoiceNoteRecorder>(),
      );
    });

    test('voiceCapture → UnavailableVoiceCapture', () {
      expect(
        container.read(voiceCaptureProvider),
        isA<UnavailableVoiceCapture>(),
      );
    });
  });

  group('selectPhotoAttacher', () {
    test('false → NoopPhotoAttacher fake', () {
      expect(selectPhotoAttacher(false), isA<NoopPhotoAttacher>());
    });

    test('true → RealPhotoAttacher (image_picker-backed)', () {
      final PhotoAttacher impl = selectPhotoAttacher(true);
      expect(impl, isA<RealPhotoAttacher>());
      expect(impl, isNot(isA<NoopPhotoAttacher>()));
    });
  });

  group('selectVoiceNoteRecorder', () {
    test('false → NoopVoiceNoteRecorder fake', () {
      expect(selectVoiceNoteRecorder(false), isA<NoopVoiceNoteRecorder>());
    });

    test('true → RealVoiceNoteRecorder (record + audioplayers)', () {
      final VoiceNoteRecorder impl = selectVoiceNoteRecorder(true);
      expect(impl, isA<RealVoiceNoteRecorder>());
      expect(impl, isNot(isA<NoopVoiceNoteRecorder>()));
      // Real recorder starts idle until a capture begins.
      expect(impl.isRecording, isFalse);
    });
  });

  group('selectVoiceCapture', () {
    test('false → UnavailableVoiceCapture stand-in', () {
      expect(selectVoiceCapture(false), isA<UnavailableVoiceCapture>());
    });

    test('true → RealVoiceCapture (speech_to_text-backed)', () {
      final VoiceCapture impl = selectVoiceCapture(true);
      expect(impl, isA<RealVoiceCapture>());
      expect(impl, isNot(isA<UnavailableVoiceCapture>()));
    });
  });
}

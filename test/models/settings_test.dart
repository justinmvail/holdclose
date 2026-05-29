import 'package:careblazers/models/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FontSizeMultiplier.scale (BUILD_SPEC.md §3.2 + §11.3)', () {
    test('maps the 4 multipliers to their spec values', () {
      expect(FontSizeMultiplier.small.scale, 0.875);
      expect(FontSizeMultiplier.medium.scale, 1.0);
      expect(FontSizeMultiplier.large.scale, 1.15);
      expect(FontSizeMultiplier.xLarge.scale, 1.35);
    });
  });

  group('AppSettings.defaults (real-build defaults)', () {
    test('audio on, normal speed, medium font, quiet hours on', () {
      final AppSettings s = AppSettings.defaults();
      expect(s.readScriptsAloud, isTrue);
      expect(s.voiceId, isNull);
      expect(s.speed, 1.0);
      expect(s.fontSize, FontSizeMultiplier.medium);
      expect(s.quietHoursEnabled, isTrue);
      expect(s.allowAudioDuringQuietHours, isFalse);
      expect(s.darkModeAtNight, isTrue);
      expect(s.resetOnLaunchDemo, isFalse);
    });
  });

  group('AppSettings JSON round-trip', () {
    test('round-trips the defaults', () {
      final AppSettings s = AppSettings.defaults();
      expect(AppSettings.fromJson(s.toJson()), equals(s));
    });

    test('round-trips a fully-customized settings shape', () {
      const AppSettings custom = AppSettings(
        readScriptsAloud: false,
        voiceId: 'com.apple.voice.compact.en-US.Samantha',
        speed: 1.3,
        fontSize: FontSizeMultiplier.xLarge,
        quietHoursEnabled: false,
        allowAudioDuringQuietHours: true,
        darkModeAtNight: false,
        resetOnLaunchDemo: true,
      );
      expect(AppSettings.fromJson(custom.toJson()), equals(custom));
    });

    test('round-trips each FontSizeMultiplier enum value', () {
      for (final FontSizeMultiplier size in FontSizeMultiplier.values) {
        final AppSettings s = AppSettings.defaults().copyWith(fontSize: size);
        expect(AppSettings.fromJson(s.toJson()).fontSize, size);
      }
    });
  });
}

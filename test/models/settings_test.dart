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
    test('audio on, normal speed, medium font, quiet hours on, bundled on',
        () {
      final AppSettings s = AppSettings.defaults();
      expect(s.readScriptsAloud, isTrue);
      expect(s.voiceId, isNull);
      expect(s.speed, 1.0);
      expect(s.fontSize, FontSizeMultiplier.medium);
      expect(s.quietHoursEnabled, isTrue);
      expect(s.allowAudioDuringQuietHours, isFalse);
      expect(s.darkModeAtNight, isTrue);
      expect(s.resetOnLaunchDemo, isFalse);
      expect(s.useBundledVoice, isTrue,
          reason: 'Phase 9.5 — bundled neural TTS is the v1 default');
    });

    test('theme preference defaults to system (follow the phone)', () {
      final AppSettings s = AppSettings.defaults();
      expect(s.themePreference, ThemePreference.system,
          reason: 'fresh install follows the phone appearance setting');
      expect(s.darkStartHour, 20);
      expect(s.darkEndHour, 7);
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
        themePreference: ThemePreference.scheduled,
        darkStartHour: 21,
        darkEndHour: 6,
      );
      expect(AppSettings.fromJson(custom.toJson()), equals(custom));
    });

    test('round-trips each ThemePreference enum value', () {
      for (final ThemePreference pref in ThemePreference.values) {
        final AppSettings s =
            AppSettings.defaults().copyWith(themePreference: pref);
        expect(AppSettings.fromJson(s.toJson()).themePreference, pref);
      }
    });

    test('legacy JSON without themePreference hydrates to system default',
        () {
      // A persisted payload from before the ThemePreference keys existed
      // (only the old darkModeAtNight bool). Missing keys fall back to the
      // @Default values rather than throwing.
      final Map<String, dynamic> legacy = AppSettings.defaults().toJson()
        ..remove('themePreference')
        ..remove('darkStartHour')
        ..remove('darkEndHour');
      final AppSettings hydrated = AppSettings.fromJson(legacy);
      expect(hydrated.themePreference, ThemePreference.system);
      expect(hydrated.darkStartHour, 20);
      expect(hydrated.darkEndHour, 7);
    });

    test('round-trips each FontSizeMultiplier enum value', () {
      for (final FontSizeMultiplier size in FontSizeMultiplier.values) {
        final AppSettings s = AppSettings.defaults().copyWith(fontSize: size);
        expect(AppSettings.fromJson(s.toJson()).fontSize, size);
      }
    });
  });
}

import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/bundled_tts_provider.dart';
import 'package:careblazers/providers/settings_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Builds a fresh container with [InMemoryStorageProvider] swapped in for
/// the real drift backend so the notifier round-trips writes through a
/// pure-Dart store. Returns both so tests can assert against the storage
/// directly after a mutator runs.
({ProviderContainer container, InMemoryStorageProvider storage})
    _build({AppSettings? seeded}) {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      storageBackendProvider.overrideWithValue(storage),
    ],
  );
  addTearDown(container.dispose);
  if (seeded != null) {
    // Pre-populate the store so the hydrate microtask snaps to a known
    // value rather than the defaults.
    storage.updateSettings(seeded);
  }
  return (container: container, storage: storage);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsNotifier — BUILD_SPEC.md §5.10 + §6.6', () {
    test('build returns AppSettings.defaults synchronously', () {
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build();
      expect(built.container.read(settingsProvider), AppSettings.defaults());
    });

    test('hydrates from storage on the next microtask', () async {
      final AppSettings persisted = AppSettings.defaults().copyWith(
        readScriptsAloud: false,
        fontSize: FontSizeMultiplier.xLarge,
        voiceId: 'Samantha|en-US',
      );
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build(seeded: persisted);

      // Read once to subscribe + kick off hydration.
      built.container.read(settingsProvider);
      // Pump microtasks so the hydrate Future runs.
      await Future<void>.delayed(Duration.zero);

      expect(built.container.read(settingsProvider), persisted);
    });

    test('setReadScriptsAloud updates state AND persists', () async {
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build();
      // Drain the hydrate microtask so we're operating on a clean default.
      await Future<void>.delayed(Duration.zero);

      final Settings notifier = built.container.read(settingsProvider.notifier);
      await notifier.setReadScriptsAloud(false);

      expect(
        built.container.read(settingsProvider).readScriptsAloud,
        isFalse,
      );
      expect(
        (await built.storage.getSettings()).readScriptsAloud,
        isFalse,
      );
    });

    test('setFontSize updates state AND persists', () async {
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build();
      await Future<void>.delayed(Duration.zero);

      final Settings notifier = built.container.read(settingsProvider.notifier);
      await notifier.setFontSize(FontSizeMultiplier.large);

      expect(
        built.container.read(settingsProvider).fontSize,
        FontSizeMultiplier.large,
      );
      expect(
        (await built.storage.getSettings()).fontSize,
        FontSizeMultiplier.large,
      );
    });

    test('every setter round-trips through storage', () async {
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build();
      await Future<void>.delayed(Duration.zero);
      final Settings n = built.container.read(settingsProvider.notifier);

      await n.setVoiceId('Daniel|en-GB');
      await n.setSpeed(1.3);
      await n.setQuietHoursEnabled(false);
      await n.setAllowAudioDuringQuietHours(true);
      await n.setDarkModeAtNight(false);
      await n.setResetOnLaunchDemo(true);

      final AppSettings stored = await built.storage.getSettings();
      expect(stored.voiceId, 'Daniel|en-GB');
      expect(stored.speed, 1.3);
      expect(stored.quietHoursEnabled, isFalse);
      expect(stored.allowAudioDuringQuietHours, isTrue);
      expect(stored.darkModeAtNight, isFalse);
      expect(stored.resetOnLaunchDemo, isTrue);
    });

    test('setVoiceId(null) clears the persisted voice override', () async {
      final ({ProviderContainer container, InMemoryStorageProvider storage})
          built = _build(
        seeded: AppSettings.defaults().copyWith(voiceId: 'Samantha|en-US'),
      );
      await Future<void>.delayed(Duration.zero);

      final Settings n = built.container.read(settingsProvider.notifier);
      await n.setVoiceId(null);

      expect(built.container.read(settingsProvider).voiceId, isNull);
      expect((await built.storage.getSettings()).voiceId, isNull);
    });
  });

  group('SettingsNotifier ↔ TTS selection', () {
    /// Wires the same override `main.dart` installs so the TTS selector
    /// reads its [AppSettings] off the [settingsProvider] notifier.
    ProviderContainer wiredContainer({
      AppSettings? seeded,
      DateTime? now,
    }) {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      if (seeded != null) {
        storage.updateSettings(seeded);
      }
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageBackendProvider.overrideWithValue(storage),
          ttsSettingsProvider.overrideWith(
            (Ref ref) => ref.watch(settingsProvider),
          ),
          if (now != null) ttsClockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('toggling readScriptsAloud OFF causes ttsProvider to return Noop',
        () async {
      // Outside quiet hours so the selection only depends on the toggle.
      final DateTime midday = DateTime(2026, 5, 29, 14, 0);
      final ProviderContainer container = wiredContainer(now: midday);

      // Drain hydrate so default-true is in state.
      await Future<void>.delayed(Duration.zero);
      expect(container.read(ttsProvider), isA<BundledTTSProvider>(),
          reason: 'default-on settings should resolve to the bundled '
              'neural-TTS path (Phase 9.5)');

      await container
          .read(settingsProvider.notifier)
          .setReadScriptsAloud(false);

      expect(container.read(ttsProvider), isA<NoopTTSProvider>(),
          reason: 'toggling read-aloud OFF must flip TTS to the no-op impl');
    });

    test('toggling useBundledVoice OFF flips ttsProvider to OSTTSProvider',
        () async {
      final DateTime midday = DateTime(2026, 5, 29, 14, 0);
      final ProviderContainer container = wiredContainer(now: midday);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(ttsProvider), isA<BundledTTSProvider>());

      await container
          .read(settingsProvider.notifier)
          .setUseBundledVoice(false);

      expect(container.read(ttsProvider), isA<OSTTSProvider>(),
          reason: 'opting out of bundled voice should fall back to OS TTS');
    });

    test('persisted readScriptsAloud=false starts with Noop after hydrate',
        () async {
      final DateTime midday = DateTime(2026, 5, 29, 14, 0);
      final ProviderContainer container = wiredContainer(
        seeded: AppSettings.defaults().copyWith(readScriptsAloud: false),
        now: midday,
      );

      // Trigger the watch chain (settingsProvider → ttsSettingsProvider
      // → ttsProvider) so build runs and the hydrate microtask is
      // scheduled. The first resolution sees defaults (audio ON) —
      // OSTTSProvider — because the persisted snapshot hasn't landed
      // yet. After draining microtasks and stream events, the
      // settingsProvider state flips to the persisted value and the
      // ttsProvider selection re-evaluates to NoopTTSProvider.
      container.read(ttsProvider);
      // Drain two microtask hops: one for the build-scheduled
      // microtask, one for the awaited getSettings() inside it.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // Pump pending stream emissions through ProviderContainer.
      await container.pump();

      expect(container.read(ttsProvider), isA<NoopTTSProvider>());
    });
  });

  group('demoModeEnabled', () {
    test('defaults to false in the test harness', () {
      // `flutter test` doesn't set the DEMO_MODE define, so the build-
      // time constant resolves to false. Sanity-check the read path:
      // the Settings screen's visibility gates rely on it.
      expect(demoModeEnabled, isFalse);
    });
  });
}

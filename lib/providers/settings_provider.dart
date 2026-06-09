import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/settings.dart';
import 'storage_provider.dart';

part 'settings_provider.g.dart';

/// Build-time flag (BUILD_SPEC.md §5.10 + §9.3 — `DEMO_MODE`).
///
/// Mirrors the same define the auth, storage, and crisis-card providers
/// consume. Read through [demoModeEnabled] so widget tests can pin the
/// value at compile time without monkey-patching.
// ignore: do_not_use_environment
const bool _demoMode = bool.fromEnvironment('DEMO_MODE', defaultValue: false);

/// True when the current build was compiled with
/// `--dart-define=DEMO_MODE=true`. Settings consults this to show the
/// Demo-mode section and hide the Account section (BUILD_SPEC.md §5.10).
bool get demoModeEnabled => _demoMode;

/// Riverpod notifier wrapping [AppSettings] (BUILD_SPEC.md §5.10 + §6.6).
///
/// The notifier hydrates from [StorageProvider.getSettings] on first
/// build — a microtask hop after the initial sync `build()` so the rest
/// of the wiring (TTS selector, theme, MediaQuery scaler) gets a usable
/// [AppSettings.defaults] frame zero, then snaps to the persisted value
/// without an `AsyncValue<AppSettings>` to thread through every consumer.
///
/// Every mutator persists via [StorageProvider.updateSettings] so a
/// rebuild (or a fresh launch) reads back the same state. The provider
/// is `keepAlive: true` — settings outlive any one screen.
@Riverpod(keepAlive: true)
class Settings extends _$Settings {
  /// Flipped the first time the caregiver mutates a setting. Guards the
  /// hydrate microtask: if the user has already written, the persisted
  /// snapshot would stomp the in-flight change (the timing surfaces in
  /// unit tests that mutate synchronously after `read(...notifier)`).
  bool _userTouched = false;

  @override
  AppSettings build() {
    // Grab the storage handle sync so the microtask doesn't reach back
    // through `ref` after this provider element's lifecycle has moved
    // on (e.g. the parent re-watched and replaced the element).
    final StorageProvider storage = ref.read(storageProvider);
    bool disposed = false;
    ref.onDispose(() {
      disposed = true;
    });
    Future<void>.microtask(() async {
      final AppSettings stored = await storage.getSettings();
      if (disposed || _userTouched) return;
      state = stored;
    });
    return AppSettings.defaults();
  }

  /// Toggle "Read scripts aloud" (BUILD_SPEC.md §5.10 — Audio section).
  /// The TTS selector watches the same [AppSettings] via the
  /// `ttsSettingsProvider` override wired in `main.dart`, so flipping
  /// this off causes `ref.read(ttsProvider)` to return [NoopTTSProvider]
  /// on the next read.
  Future<void> setReadScriptsAloud(bool value) =>
      _update(state.copyWith(readScriptsAloud: value));

  /// Persist the selected voice id (`"<name>|<locale>"`, the same
  /// encoding [OSTTSProvider.encodeVoiceId] produces). Null clears the
  /// override and falls back to the system default.
  Future<void> setVoiceId(String? value) =>
      _update(state.copyWith(voiceId: value));

  /// Toggle "High-quality bundled voice" (BUILD_SPEC.md Phase 9 — Piper
  /// neural TTS bundled at ~30 MB). When true the [ttsProvider] factory
  /// routes through [BundledTTSProvider] so the on-device Amy voice
  /// plays; when false it falls back to [OSTTSProvider] (the platform
  /// flutter_tts engine).
  Future<void> setUseBundledVoice(bool value) =>
      _update(state.copyWith(useBundledVoice: value));

  /// Persist the speech-rate multiplier (BUILD_SPEC.md §11.1 —
  /// 0.7×/1.0×/1.3× presets). The TTS provider clamps out-of-range
  /// values; this setter does not.
  Future<void> setSpeed(double value) =>
      _update(state.copyWith(speed: value));

  /// Persist the type-ramp multiplier (BUILD_SPEC.md §11.3). The app
  /// root wraps MaterialApp with a MediaQuery that derives its
  /// `textScaler` from `state.fontSize.scale`.
  Future<void> setFontSize(FontSizeMultiplier value) =>
      _update(state.copyWith(fontSize: value));

  /// Toggle the default 10pm–7am quiet-hours mute (BUILD_SPEC.md §11.2).
  Future<void> setQuietHoursEnabled(bool value) =>
      _update(state.copyWith(quietHoursEnabled: value));

  /// Toggle the per-user override that lets audio play even during
  /// quiet hours (BUILD_SPEC.md §5.10 + §11.2).
  Future<void> setAllowAudioDuringQuietHours(bool value) =>
      _update(state.copyWith(allowAudioDuringQuietHours: value));

  /// Set the quiet-hours window bounds (whole hour-of-day, 0–23). The
  /// window wraps midnight when start > end. Hours are normalised into
  /// 0–23 so a picker can't persist an out-of-range value.
  Future<void> setQuietHoursWindow({
    required int startHour,
    required int endHour,
  }) =>
      _update(state.copyWith(
        quietHoursStartHour: startHour % 24,
        quietHoursEndHour: endHour % 24,
      ));

  /// Toggle the auto-dark-after-6pm behavior (BUILD_SPEC.md §11.4).
  ///
  /// Legacy setter kept for back-compat callers; the appearance UI now
  /// drives [setThemePreference] / [setDarkWindow] instead.
  Future<void> setDarkModeAtNight(bool value) =>
      _update(state.copyWith(darkModeAtNight: value));

  /// Set how the app chooses between the light and dark palettes
  /// (BUILD_SPEC.md §11.4 — system / on / off / scheduled). The
  /// [nightThemeModeProvider] re-evaluates the moment this lands.
  Future<void> setThemePreference(ThemePreference value) =>
      _update(state.copyWith(themePreference: value));

  /// Set the scheduled dark-mode window bounds (whole hour-of-day,
  /// 0–23). Only consulted when [AppSettings.themePreference] is
  /// [ThemePreference.scheduled]; the window wraps midnight when start >
  /// end. Hours are normalised into 0–23 so a picker can't persist an
  /// out-of-range value.
  Future<void> setDarkWindow({
    required int startHour,
    required int endHour,
  }) =>
      _update(state.copyWith(
        darkStartHour: startHour % 24,
        darkEndHour: endHour % 24,
      ));

  /// Toggle "Reset on launch" — visible only in [demoModeEnabled]
  /// builds (BUILD_SPEC.md §5.10 + §9.3).
  Future<void> setResetOnLaunchDemo(bool value) =>
      _update(state.copyWith(resetOnLaunchDemo: value));

  /// Master toggle for whether the app schedules local notifications
  /// (Phase 12.8). Distinct from the OS-level permission grant — even
  /// with this on, the platform plugin will silently no-op if the
  /// caregiver denied notifications at the OS level.
  Future<void> setNotificationsEnabled(bool value) =>
      _update(state.copyWith(notificationsEnabled: value));

  /// Whether to serve the community surface from the in-memory fake
  /// instead of the deployed Cloudflare Worker (home-refactor). Flips
  /// the [forumApiClientProvider] selection live; existing feed reads
  /// keep their data but the next refresh reloads against the new
  /// client.
  Future<void> setUseDemoForum(bool value) =>
      _update(state.copyWith(useDemoForum: value));

  /// Opt the Care Team tab into its full coordination hub. Off by
  /// default — solo caregivers see a single "Coordinate care" CTA in
  /// the Team tab instead. Flipping on lights up Calendar / Tasks /
  /// Shifts / Expenses / Circle without an app restart.
  Future<void> setTeamCoordinationEnabled(bool value) =>
      _update(state.copyWith(teamCoordinationEnabled: value));

  Future<void> _update(AppSettings next) async {
    _userTouched = true;
    state = next;
    await ref.read(storageProvider).updateSettings(next);
  }
}

import 'package:freezed_annotation/freezed_annotation.dart';

part 'settings.freezed.dart';
part 'settings.g.dart';

/// Font-size multiplier (BUILD_SPEC.md §3.2 + §11.3). Applied to
/// `MediaQuery.textScaler` at the app root.
enum FontSizeMultiplier {
  small,
  medium,
  large,
  xLarge,
}

/// How the app decides between the light and dark palettes
/// (BUILD_SPEC.md §11.4). Replaces the single `darkModeAtNight` bool.
///
///  - [system]    → follow the phone's appearance setting
///                  ([ThemeMode.system]). The out-of-the-box default so
///                  testers see whatever their device is already on.
///  - [on]        → always dark ([ThemeMode.dark]).
///  - [off]       → always light ([ThemeMode.light]).
///  - [scheduled] → dark inside a user-set window (the old "dark at
///                  night" behavior, now with customizable hours that
///                  wrap midnight like the quiet-hours window).
enum ThemePreference {
  system,
  on,
  off,
  scheduled,
}

extension FontSizeMultiplierScale on FontSizeMultiplier {
  /// The multiplier value the type ramp scales by. Per BUILD_SPEC.md
  /// §3.2: 0.875× / 1.0× / 1.15× / 1.35×.
  double get scale {
    switch (this) {
      case FontSizeMultiplier.small:
        return 0.875;
      case FontSizeMultiplier.medium:
        return 1.0;
      case FontSizeMultiplier.large:
        return 1.15;
      case FontSizeMultiplier.xLarge:
        return 1.35;
    }
  }
}

/// All user-tunable preferences (BUILD_SPEC.md §5.10 + §11).
///
/// Persisted via [StorageProvider.updateSettings] on every change.
/// Defaults match BUILD_SPEC.md §9.3 demo-mode defaults; real-build
/// defaults are constructed via [AppSettings.defaults].
@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    required bool readScriptsAloud,
    String? voiceId,
    required double speed,
    required FontSizeMultiplier fontSize,
    required bool quietHoursEnabled,
    required bool allowAudioDuringQuietHours,
    required bool darkModeAtNight,
    required bool resetOnLaunchDemo,

    /// How the app chooses between the light and dark palettes
    /// (BUILD_SPEC.md §11.4). Defaults to [ThemePreference.system] so a
    /// fresh install follows the phone's appearance setting — what most
    /// testers expect. Supersedes the legacy `darkModeAtNight` bool above,
    /// which is now unused but retained so already-persisted JSON keeps
    /// hydrating cleanly.
    @Default(ThemePreference.system) ThemePreference themePreference,

    /// Scheduled dark-mode window, as whole hour-of-day bounds
    /// [darkStartHour, darkEndHour). Only consulted when
    /// [themePreference] is [ThemePreference.scheduled]. Wraps midnight
    /// when start > end (the default 20→7 means 8pm through 7am, the same
    /// shape as the quiet-hours window). `@Default` keeps pre-existing
    /// settings JSON (which predates these keys) hydrating to the
    /// hardcoded defaults.
    @Default(20) int darkStartHour,
    @Default(7) int darkEndHour,

    /// Quiet-hours window, as whole-hour-of-day bounds [start, end). The
    /// window wraps past midnight when start > end (the default 22→7 means
    /// 10pm through 7am). `@Default` keeps already-persisted settings JSON
    /// (which predates these keys) hydrating cleanly to the old hardcoded
    /// 22/7 values. See [defaultQuietHoursStart] / [defaultQuietHoursEnd].
    @Default(22) int quietHoursStartHour,
    @Default(7) int quietHoursEndHour,
    @Default(true) bool useBundledVoice,

    /// Per-feature toggle for whether the app schedules local
    /// notifications at all (Phase 12.8 master). Lets a caregiver
    /// keep the tracker UIs but suppress OS reminders without
    /// touching the system-level permission. Defaults to true so the
    /// "permission ask on first add" flow has a target to flip on
    /// when the OS grant lands.
    @Default(true) bool notificationsEnabled,

    /// Whether the community forum surfaces should hit a deterministic
    /// in-memory fake instead of the Cloudflare Workers backend
    /// (home-refactor follow-up). Default true so a TestFlight build
    /// without a deployed Worker still demos cleanly; operator flips
    /// off in Settings once the real backend is wired.
    @Default(true) bool useDemoForum,

    /// Whether the Care Team tab surfaces the full coordination
    /// hub (Calendar, Tasks, Shifts, Expenses, Circle). Defaults
    /// to **on** so the coordination features are available out of the
    /// box. Toggle off in Settings → Care Team and the tab body swaps to
    /// a "Coordinate care" CTA that turns it back on with one tap; the
    /// bottom tab stays mounted either way so the 5-tab IA invariant holds.
    @Default(true) bool teamCoordinationEnabled,
  }) = _AppSettings;

  /// Hydrate from persisted JSON. Unknown keys are silently ignored —
  /// json_serializable does not set `disallowUnrecognizedKeys`, so demo
  /// seed + pre-existing user state that still carries the removed
  /// Phase 12.8 tracker keys (`useTrackers`, `medicationsEnabled`,
  /// `appointmentsEnabled`) hydrates clean without throwing.
  factory AppSettings.fromJson(Map<String, dynamic> json) =>
      _$AppSettingsFromJson(json);

  /// Real-build defaults: audio on, normal speed, medium font, quiet
  /// hours on, dark-mode-at-night on, demo reset off.
  factory AppSettings.defaults() => const AppSettings(
        readScriptsAloud: true,
        voiceId: null,
        speed: 1.0,
        fontSize: FontSizeMultiplier.medium,
        quietHoursEnabled: true,
        allowAudioDuringQuietHours: false,
        darkModeAtNight: true,
        resetOnLaunchDemo: false,
      );
}

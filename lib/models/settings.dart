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
    @Default(true) bool useBundledVoice,

    /// Master "Use trackers" switch (BUILD_SPEC.md Phase 12.8). When
    /// false, the Medications + Appointments tabs hide and no
    /// notifications are scheduled — the lean-app mode for caregivers
    /// who don't want the structured tracker surfaces.
    @Default(true) bool useTrackers,

    /// Per-feature toggle for the Medications tab + reminder
    /// scheduling. Overrides [useTrackers] only by being false — if
    /// the master is off, this can't be on.
    @Default(true) bool medicationsEnabled,

    /// Per-feature toggle for the Appointments tab + reminder
    /// scheduling. Same precedence rule as [medicationsEnabled].
    @Default(true) bool appointmentsEnabled,

    /// Per-feature toggle for whether the app schedules local
    /// notifications at all (Phase 12.8 master). Lets a caregiver
    /// keep the tracker UIs but suppress OS reminders without
    /// touching the system-level permission. Defaults to true so the
    /// "permission ask on first add" flow has a target to flip on
    /// when the OS grant lands.
    @Default(true) bool notificationsEnabled,
  }) = _AppSettings;

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

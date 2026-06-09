import 'dart:async';

import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/settings.dart';
import 'settings_provider.dart';
import 'tts_provider.dart' show isQuietHoursActive;

part 'quiet_hours_provider.g.dart';

/// Hour at which `darkModeAtNight` flips the theme to dark
/// (BUILD_SPEC.md §11.4 — "Auto-applied after 6pm local time").
///
/// Same shape as [defaultQuietHoursStart] in `tts_provider.dart` — a
/// bare local-hour comparison so the threshold is testable as a pure
/// function without dragging a Riverpod container into the assertion.
const int defaultDarkModeStartHour = 18;

/// True when [now]'s local hour is at-or-past the dark-mode switch hour.
/// Pure function so the threshold can be asserted without a container.
bool isAfterDarkModeStart(
  DateTime now, {
  int startHour = defaultDarkModeStartHour,
}) {
  return now.hour >= startHour;
}

/// Cadence at which the auto-switches re-read the wall clock. One
/// minute is enough resolution for hour-boundary transitions (10pm →
/// quiet, 7am → not quiet, 6pm → dark, etc.) without rebuilding the
/// provider tree on every frame.
const Duration quietHoursPollInterval = Duration(minutes: 1);

/// Wall clock the auto-switches consult. Overridable so unit tests pin
/// a deterministic hour without touching system time — mirrors the
/// pattern [ttsClockProvider] uses for the TTS quiet-hours mute.
@Riverpod(keepAlive: true)
DateTime Function() quietHoursClock(Ref ref) => DateTime.now;

/// True when the caregiver's quiet-hours window is currently in effect
/// (BUILD_SPEC.md §11.2).
///
/// Recomputes once per minute via [Timer.periodic] so the transition
/// in/out of the window happens without the caregiver touching the app
/// — useful for ambient UI cues that key off "is it nighttime right
/// now?" beyond the TTS mute already wired in `tts_provider.dart`.
///
/// Returns `false` whenever `settings.quietHoursEnabled` is off — the
/// window only matters when the toggle is on. The
/// `allowAudioDuringQuietHours` override is a TTS-mute concern, not a
/// "is the window active" concern, and stays out of this provider; the
/// TTS selector in `tts_provider.dart` continues to own that decision.
@Riverpod(keepAlive: true)
class QuietHoursActive extends _$QuietHoursActive {
  Timer? _timer;

  @override
  bool build() {
    _timer = Timer.periodic(quietHoursPollInterval, (_) => _refresh());
    ref.onDispose(() => _timer?.cancel());
    // Recompute eagerly when the caregiver toggles the setting so the
    // UI flips on the same frame instead of waiting for the next tick.
    ref.listen<AppSettings>(settingsProvider, (_, __) => _refresh());
    return _compute();
  }

  void _refresh() {
    final bool next = _compute();
    if (next != state) state = next;
  }

  bool _compute() {
    final AppSettings settings = ref.read(settingsProvider);
    final DateTime now = ref.read(quietHoursClockProvider)();
    if (!settings.quietHoursEnabled) return false;
    return isQuietHoursActive(
      now,
      startHour: settings.quietHoursStartHour,
      endHour: settings.quietHoursEndHour,
    );
  }
}

/// The `MaterialApp.themeMode` value the app root applies
/// (BUILD_SPEC.md §11.4).
///
/// Honors [AppSettings.themePreference]:
///   - [ThemePreference.system]    → [ThemeMode.system] (follow the phone)
///   - [ThemePreference.on]        → [ThemeMode.dark]   (always dark)
///   - [ThemePreference.off]       → [ThemeMode.light]  (always light)
///   - [ThemePreference.scheduled] → dark inside the user-set
///     [darkStartHour, darkEndHour) window (wrapping midnight like the
///     quiet-hours window), light outside it.
///
/// Polls the same one-minute cadence as [QuietHoursActive] so the
/// scheduled flip happens without app interaction. The listener on
/// [settingsProvider] re-evaluates immediately when the caregiver
/// changes the preference or window in Settings.
@Riverpod(keepAlive: true)
class NightThemeMode extends _$NightThemeMode {
  Timer? _timer;

  @override
  ThemeMode build() {
    _timer = Timer.periodic(quietHoursPollInterval, (_) => _refresh());
    ref.onDispose(() => _timer?.cancel());
    ref.listen<AppSettings>(settingsProvider, (_, __) => _refresh());
    return _compute();
  }

  void _refresh() {
    final ThemeMode next = _compute();
    if (next != state) state = next;
  }

  ThemeMode _compute() {
    final AppSettings settings = ref.read(settingsProvider);
    final DateTime now = ref.read(quietHoursClockProvider)();
    switch (settings.themePreference) {
      case ThemePreference.system:
        return ThemeMode.system;
      case ThemePreference.on:
        return ThemeMode.dark;
      case ThemePreference.off:
        return ThemeMode.light;
      case ThemePreference.scheduled:
        return isQuietHoursActive(
          now,
          startHour: settings.darkStartHour,
          endHour: settings.darkEndHour,
        )
            ? ThemeMode.dark
            : ThemeMode.light;
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/settings.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/data_exporter.dart';
import '../../services/forum_api_client.dart' show forumBackendConfigured;
import '../../theme.dart';
import '../../widgets/holdclose_switch.dart';
import '../../widgets/path_header.dart';
import 'loved_ones_screen.dart' show LovedOnesScreen;

/// Compact styling shared by the Settings segmented controls (Font size,
/// Dark mode). Four equal-width segments with longer labels ("X-Large",
/// "Scheduled") were wrapping to two lines on phone widths; tightening the
/// horizontal padding + label size, dropping the selection checkmark, and
/// forcing single-line labels keeps every option on one line.
final ButtonStyle _compactSegmentStyle = SegmentedButton.styleFrom(
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
);

/// Settings (BUILD_SPEC.md §5.10).
///
/// Single scrollable surface holding every user preference. Each
/// control reads through [settingsProvider] and writes via one of the
/// typed setters on the notifier; the persisted [AppSettings] then
/// re-flows into `ttsSettingsProvider` (via the override wired in
/// `main.dart`) and the app-root MediaQuery so TTS muting + font
/// scaling track the change without per-screen plumbing.
///
/// Visibility is gated on the `DEMO_MODE` build define
/// ([demoModeEnabled]):
///   - Demo-mode section is visible only when the define is set.
///   - Account section is visible only when it is not — real builds
///     show sign-out / delete-account; the demo tour skips them.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const Key readAloudToggleKey = Key('settings-read-aloud-toggle');
  static const Key bundledVoiceToggleKey =
      Key('settings-bundled-voice-toggle');
  static const Key voicePickerKey = Key('settings-voice-picker');
  static const Key speedSliderKey = Key('settings-speed-slider');
  static const Key quietHoursToggleKey = Key('settings-quiet-hours-toggle');
  static const Key quietHoursStartPickerKey =
      Key('settings-quiet-hours-start-picker');
  static const Key quietHoursEndPickerKey =
      Key('settings-quiet-hours-end-picker');
  static const Key allowAudioToggleKey = Key('settings-allow-audio-toggle');
  static const Key fontSizeSegmentedKey = Key('settings-font-size-segmented');
  static const Key themePreferenceKey = Key('settings-theme-preference');
  static const Key darkStartPickerKey = Key('settings-dark-start-picker');
  static const Key darkEndPickerKey = Key('settings-dark-end-picker');
  static const Key demoSectionKey = Key('settings-demo-section');
  static const Key resetOnLaunchToggleKey =
      Key('settings-reset-on-launch-toggle');
  static const Key reloadSeedButtonKey = Key('settings-reload-seed');
  static const Key accountSectionKey = Key('settings-account-section');
  static const Key signOutButtonKey = Key('settings-sign-out');
  static const Key deleteAccountButtonKey = Key('settings-delete-account');
  static const Key deleteAccountConfirmKey =
      Key('settings-delete-account-confirm');
  static const Key notificationsToggleKey =
      Key('settings-notifications-toggle');
  static const Key trackersSectionKey = Key('settings-trackers-section');
  static const Key useDemoForumToggleKey =
      Key('settings-use-demo-forum-toggle');
  static const Key careTeamSectionKey = Key('settings-care-team-section');
  static const Key teamCoordinationToggleKey =
      Key('settings-team-coordination-toggle');
  static const Key dataSectionKey = Key('settings-data-section');
  static const Key backupDataButtonKey = Key('settings-backup-data');
  static const Key lovedOnesSectionKey = Key('settings-loved-ones-section');
  static const Key lovedOnesRowKey = Key('settings-loved-ones-row');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    final Settings notifier = ref.read(settingsProvider.notifier);

    // Settings is pushed onto the root navigator from Home. On Android the
    // system Back must return to Home — not exit the whole app (alpha bug,
    // 2026-06-06; still exiting on Amanda's device 2026-06-07). The previous
    // `canPop: router.canPop()` let the system pop proceed whenever a route
    // sat beneath — but on the root navigator above the shell that pop could
    // tear the whole stack down and close the app. So with a router present
    // we ALWAYS block the system pop (`canPop: false`) and route Home
    // ourselves, which is deterministic regardless of how `/settings` was
    // entered (push, `go`, or deep link). Without a router (widget tests /
    // goldens) the PopScope is a passthrough so the OS back still works.
    final GoRouter? router = GoRouter.maybeOf(context);
    return PopScope(
      canPop: router == null,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop || router == null) return;
        router.go('/');
      },
      child: Scaffold(
        backgroundColor: context.cb.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: <Widget>[
            const PathHeader(
              breadcrumbs: <PathHeaderCrumb>[
                PathHeaderCrumb(label: 'Home', route: '/'),
                PathHeaderCrumb(label: 'Settings'),
              ],
              title: 'Settings',
              backLabel: 'Back to Home',
              leadingIcon: Icons.settings_outlined,
            ),
            const SizedBox(height: 20),
            const _LovedOnesSection(),
            const SizedBox(height: 24),
            _AudioSection(settings: settings, notifier: notifier),
            const SizedBox(height: 24),
            _FontSizeSection(settings: settings, notifier: notifier),
            const SizedBox(height: 24),
            _AppearanceSection(settings: settings, notifier: notifier),
            const SizedBox(height: 24),
            _TrackersSection(settings: settings, notifier: notifier),
            const SizedBox(height: 24),
            _CareTeamSection(settings: settings, notifier: notifier),
            const SizedBox(height: 24),
            const _DataSection(),
            if (demoModeEnabled) ...<Widget>[
              const SizedBox(height: 24),
              _DemoSection(settings: settings, notifier: notifier),
            ],
            if (!demoModeEnabled) ...<Widget>[
              const SizedBox(height: 24),
              const _AccountSection(),
            ],
            const SizedBox(height: 24),
            const _AboutSection(),
          ],
        ),
      ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: context.cb.primary,
            ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.cb.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Loved ones (multi-patient, Issue #6) — entry to the switcher/manager
// ---------------------------------------------------------------------------

/// Settings card linking to the "Loved ones" manager (multi-patient,
/// Issue #6). One row → [LovedOnesScreen], where the caregiver switches
/// the active loved one or adds another. Kept out of the way (a plain
/// navigation row) since most caregivers manage a single person.
class _LovedOnesSection extends StatelessWidget {
  const _LovedOnesSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: SettingsScreen.lovedOnesSectionKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Loved ones'),
        _SectionCard(
          child: ListTile(
            key: SettingsScreen.lovedOnesRowKey,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.people_alt_outlined,
              color: context.cb.primary,
            ),
            title: const Text('Loved ones'),
            subtitle: const Text(
              'Switch between the people you care for, or add another.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/loved-ones'),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Audio section (BUILD_SPEC.md §5.10 + §11.1 + §11.2)
// ---------------------------------------------------------------------------

class _AudioSection extends ConsumerWidget {
  const _AudioSection({required this.settings, required this.notifier});

  final AppSettings settings;
  final Settings notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool audioOn = settings.readScriptsAloud;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Read scripts aloud'),
        _SectionCard(
          child: Column(
            children: <Widget>[
              HoldcloseSwitchListTile(
                key: SettingsScreen.readAloudToggleKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('Read scripts aloud'),
                subtitle: const Text(
                  'Plays the coaching scripts through your phone voice.',
                ),
                value: audioOn,
                onChanged: (bool v) => notifier.setReadScriptsAloud(v),
              ),
              const Divider(height: 1),
              HoldcloseSwitchListTile(
                key: SettingsScreen.bundledVoiceToggleKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('High-quality bundled voice'),
                subtitle: const Text(
                  'Uses ~30 MB of storage for a natural-sounding offline '
                  'voice (recommended).',
                ),
                value: settings.useBundledVoice,
                onChanged:
                    audioOn ? (bool v) => notifier.setUseBundledVoice(v) : null,
              ),
              const Divider(height: 1),
              _VoicePicker(
                settings: settings,
                notifier: notifier,
                enabled: audioOn,
              ),
              const Divider(height: 1),
              _SpeedSlider(
                settings: settings,
                notifier: notifier,
                enabled: audioOn,
              ),
              const Divider(height: 1),
              HoldcloseSwitchListTile(
                key: SettingsScreen.quietHoursToggleKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('Quiet hours'),
                subtitle: Text(
                  'Mute audio between '
                  '${formatHourOfDay(settings.quietHoursStartHour)} and '
                  '${formatHourOfDay(settings.quietHoursEndHour)}.',
                ),
                value: settings.quietHoursEnabled,
                onChanged:
                    audioOn ? (bool v) => notifier.setQuietHoursEnabled(v) : null,
              ),
              _QuietHoursWindowRow(
                settings: settings,
                notifier: notifier,
                enabled: audioOn && settings.quietHoursEnabled,
              ),
              const Divider(height: 1),
              HoldcloseSwitchListTile(
                key: SettingsScreen.allowAudioToggleKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('Always allow audio'),
                subtitle: const Text(
                  'Override quiet hours and play sound anyway.',
                ),
                value: settings.allowAudioDuringQuietHours,
                onChanged: audioOn
                    ? (bool v) => notifier.setAllowAudioDuringQuietHours(v)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Format a whole hour-of-day (0–23) as a friendly 12-hour clock label,
/// e.g. 0 → "12 AM", 13 → "1 PM", 22 → "10 PM". Shared by the quiet-hours
/// subtitle and the window picker.
String formatHourOfDay(int hour) {
  final int h = hour % 24;
  final String suffix = h < 12 ? 'AM' : 'PM';
  final int twelve = h % 12 == 0 ? 12 : h % 12;
  return '$twelve $suffix';
}

/// Two compact hour pickers ("From … To …") that set the quiet-hours
/// window. Whole-hour granularity matches the [AppSettings.quietHoursStartHour]
/// / [AppSettings.quietHoursEndHour] model; the window wraps midnight when
/// From > To. Disabled (greyed, non-interactive) when audio is off or quiet
/// hours is toggled off.
class _QuietHoursWindowRow extends StatelessWidget {
  const _QuietHoursWindowRow({
    required this.settings,
    required this.notifier,
    required this.enabled,
  });

  final AppSettings settings;
  final Settings notifier;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final TextStyle labelStyle = TextStyle(
      color: enabled
          ? context.cb.text
          : context.cb.text.withValues(alpha: 0.4),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: <Widget>[
          Text('From', style: labelStyle),
          const SizedBox(width: 8),
          _HourDropdown(
            dropdownKey: SettingsScreen.quietHoursStartPickerKey,
            value: settings.quietHoursStartHour,
            enabled: enabled,
            onChanged: (int h) => notifier.setQuietHoursWindow(
              startHour: h,
              endHour: settings.quietHoursEndHour,
            ),
          ),
          const SizedBox(width: 16),
          Text('to', style: labelStyle),
          const SizedBox(width: 8),
          _HourDropdown(
            dropdownKey: SettingsScreen.quietHoursEndPickerKey,
            value: settings.quietHoursEndHour,
            enabled: enabled,
            onChanged: (int h) => notifier.setQuietHoursWindow(
              startHour: settings.quietHoursStartHour,
              endHour: h,
            ),
          ),
        ],
      ),
    );
  }
}

class _HourDropdown extends StatelessWidget {
  const _HourDropdown({
    required this.dropdownKey,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final Key dropdownKey;
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<int>(
      key: dropdownKey,
      value: value,
      isDense: true,
      underline: const SizedBox.shrink(),
      onChanged: enabled
          ? (int? h) {
              if (h != null) onChanged(h);
            }
          : null,
      items: <DropdownMenuItem<int>>[
        for (int h = 0; h < 24; h++)
          DropdownMenuItem<int>(
            value: h,
            child: Text(formatHourOfDay(h)),
          ),
      ],
    );
  }
}

/// Voice picker (BUILD_SPEC.md Phase 9.5).
///
/// v1 ships one bundled voice — Amy, the en_US Piper voice the
/// platform bridges play back from `assets/tts/en_US-amy-medium/`. The
/// dropdown is a single-item placeholder until the v1.1 catalog adds
/// Dr. Natali + the other personalities the voicecloner repo produces.
class _VoicePicker extends StatelessWidget {
  const _VoicePicker({
    required this.settings,
    required this.notifier,
    required this.enabled,
  });

  /// Encoded voice id the BundledTTSProvider's native side recognises
  /// (see `BundledTTSProvider.availableVoices()` in
  /// `lib/providers/bundled_tts_provider.dart`).
  static const String _amyVoiceId = 'amy|en_US';

  final AppSettings settings;
  final Settings notifier;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          const Expanded(child: Text('Voice')),
          DropdownButton<String>(
            key: SettingsScreen.voicePickerKey,
            value: _amyVoiceId,
            onChanged: enabled
                ? (String? next) {
                    if (next != null) notifier.setVoiceId(next);
                  }
                : null,
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: _amyVoiceId,
                child: Text('Amy (bundled)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpeedSlider extends StatelessWidget {
  const _SpeedSlider({
    required this.settings,
    required this.notifier,
    required this.enabled,
  });

  final AppSettings settings;
  final Settings notifier;
  final bool enabled;

  static const List<double> _presets = <double>[0.7, 1.0, 1.3];

  @override
  Widget build(BuildContext context) {
    // Snap to the nearest preset so the slider's label stays in the
    // documented "slow / normal / fast" vocabulary (BUILD_SPEC.md §11.1).
    final int index = _nearestPresetIndex(settings.speed);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: Text('Speed')),
              Text(_label(index)),
            ],
          ),
          Slider(
            key: SettingsScreen.speedSliderKey,
            value: index.toDouble(),
            min: 0,
            max: 2,
            divisions: 2,
            label: _label(index),
            onChanged: enabled
                ? (double v) => notifier.setSpeed(_presets[v.round()])
                : null,
          ),
        ],
      ),
    );
  }

  int _nearestPresetIndex(double value) {
    int best = 0;
    double bestDelta = (value - _presets[0]).abs();
    for (int i = 1; i < _presets.length; i++) {
      final double delta = (value - _presets[i]).abs();
      if (delta < bestDelta) {
        best = i;
        bestDelta = delta;
      }
    }
    return best;
  }

  String _label(int index) {
    switch (index) {
      case 0:
        return 'Slow';
      case 1:
        return 'Normal';
      case 2:
        return 'Fast';
      default:
        return 'Normal';
    }
  }
}

// ---------------------------------------------------------------------------
// Font size (BUILD_SPEC.md §5.10 + §11.3)
// ---------------------------------------------------------------------------

class _FontSizeSection extends StatelessWidget {
  const _FontSizeSection({required this.settings, required this.notifier});

  final AppSettings settings;
  final Settings notifier;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Font size'),
        _SectionCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SegmentedButton<FontSizeMultiplier>(
              key: SettingsScreen.fontSizeSegmentedKey,
              style: _compactSegmentStyle,
              showSelectedIcon: false,
              segments: const <ButtonSegment<FontSizeMultiplier>>[
                ButtonSegment<FontSizeMultiplier>(
                  value: FontSizeMultiplier.small,
                  label: Text('Small', maxLines: 1, softWrap: false),
                ),
                ButtonSegment<FontSizeMultiplier>(
                  value: FontSizeMultiplier.medium,
                  label: Text('Medium', maxLines: 1, softWrap: false),
                ),
                ButtonSegment<FontSizeMultiplier>(
                  value: FontSizeMultiplier.large,
                  label: Text('Large', maxLines: 1, softWrap: false),
                ),
                ButtonSegment<FontSizeMultiplier>(
                  value: FontSizeMultiplier.xLarge,
                  label: Text('X-Large', maxLines: 1, softWrap: false),
                ),
              ],
              selected: <FontSizeMultiplier>{settings.fontSize},
              onSelectionChanged: (Set<FontSizeMultiplier> next) =>
                  notifier.setFontSize(next.first),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Appearance (BUILD_SPEC.md §5.10 + §11.4)
// ---------------------------------------------------------------------------

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection({required this.settings, required this.notifier});

  final AppSettings settings;
  final Settings notifier;

  /// Human-readable subtitle describing the active dark-mode behavior.
  String _subtitle() {
    switch (settings.themePreference) {
      case ThemePreference.system:
        return 'Matches your phone’s light or dark setting.';
      case ThemePreference.on:
        return 'Always uses the navy dark palette.';
      case ThemePreference.off:
        return 'Always uses the light palette.';
      case ThemePreference.scheduled:
        return 'Dark between '
            '${formatHourOfDay(settings.darkStartHour)} and '
            '${formatHourOfDay(settings.darkEndHour)}.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool scheduled =
        settings.themePreference == ThemePreference.scheduled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Appearance'),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Dark mode'),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _subtitle(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.cb.text.withValues(alpha: 0.6),
                      ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SegmentedButton<ThemePreference>(
                  key: SettingsScreen.themePreferenceKey,
                  style: _compactSegmentStyle,
                  segments: const <ButtonSegment<ThemePreference>>[
                    ButtonSegment<ThemePreference>(
                      value: ThemePreference.system,
                      label: Text('System', maxLines: 1, softWrap: false),
                    ),
                    ButtonSegment<ThemePreference>(
                      value: ThemePreference.on,
                      label: Text('On', maxLines: 1, softWrap: false),
                    ),
                    ButtonSegment<ThemePreference>(
                      value: ThemePreference.off,
                      label: Text('Off', maxLines: 1, softWrap: false),
                    ),
                    ButtonSegment<ThemePreference>(
                      value: ThemePreference.scheduled,
                      label: Text('Scheduled', maxLines: 1, softWrap: false),
                    ),
                  ],
                  selected: <ThemePreference>{settings.themePreference},
                  showSelectedIcon: false,
                  onSelectionChanged: (Set<ThemePreference> next) =>
                      notifier.setThemePreference(next.first),
                ),
              ),
              if (scheduled)
                _DarkWindowRow(settings: settings, notifier: notifier),
            ],
          ),
        ),
      ],
    );
  }
}

/// Two compact hour pickers ("From … To …") that set the scheduled
/// dark-mode window — same shape and style as [_QuietHoursWindowRow].
/// Shown only when [ThemePreference.scheduled] is selected; the window
/// wraps midnight when From > To.
class _DarkWindowRow extends StatelessWidget {
  const _DarkWindowRow({required this.settings, required this.notifier});

  final AppSettings settings;
  final Settings notifier;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: <Widget>[
          const Text('From'),
          const SizedBox(width: 8),
          _HourDropdown(
            dropdownKey: SettingsScreen.darkStartPickerKey,
            value: settings.darkStartHour,
            enabled: true,
            onChanged: (int h) => notifier.setDarkWindow(
              startHour: h,
              endHour: settings.darkEndHour,
            ),
          ),
          const SizedBox(width: 16),
          const Text('to'),
          const SizedBox(width: 8),
          _HourDropdown(
            dropdownKey: SettingsScreen.darkEndPickerKey,
            value: settings.darkEndHour,
            enabled: true,
            onChanged: (int h) => notifier.setDarkWindow(
              startHour: settings.darkStartHour,
              endHour: h,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Trackers (BUILD_SPEC.md Phase 12.8) — master + per-feature toggles
// ---------------------------------------------------------------------------

/// Settings card for the medication + appointment trackers
/// (BUILD_SPEC.md Phase 12.8).
///
/// Two controls stacked:
///   - "Send reminders" — master for whether the app schedules local
///     notifications for the tracker surfaces at all.
///   - "Use demo community" — serves the Community tab from the
///     on-device fake instead of the live backend.
///
/// The notifier setters persist immediately via the storage provider
/// (same pattern as the audio + appearance sections).
class _TrackersSection extends StatelessWidget {
  const _TrackersSection({required this.settings, required this.notifier});

  final AppSettings settings;
  final Settings notifier;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: SettingsScreen.trackersSectionKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Trackers'),
        _SectionCard(
          child: Column(
            children: <Widget>[
              HoldcloseSwitchListTile(
                key: SettingsScreen.notificationsToggleKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('Send reminders'),
                subtitle: const Text(
                  "When off, the app stops scheduling new reminders. "
                  "Already-pending ones are cleared next time you edit "
                  'a medication or appointment.',
                ),
                value: settings.notificationsEnabled,
                onChanged: (bool v) => notifier.setNotificationsEnabled(v),
              ),
              // The "Use demo community" toggle only has an effect when no
              // forum backend is baked in (FORUM_API_URL unset) — in
              // alpha/prod builds the real client is always used regardless
              // of the toggle, so hide it there to avoid confusing real users.
              if (!forumBackendConfigured) ...<Widget>[
                const Divider(height: 1),
                HoldcloseSwitchListTile(
                  key: SettingsScreen.useDemoForumToggleKey,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use demo community'),
                  subtitle: const Text(
                    'When on, the Community tab serves seed posts from an '
                    'on-device fake instead of the live backend. Useful '
                    'before the backend is deployed; flip off once your '
                    'team is using the real forum.',
                  ),
                  value: settings.useDemoForum,
                  onChanged: (bool v) => notifier.setUseDemoForum(v),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Care Circle coordination toggle — surfaces the "Care Circle" hub under
// the Care tab (Tasks / Shifts / People / Activity / Expenses). Off by
// default; when off, the Care hub simply omits the Care Circle tile.
// ---------------------------------------------------------------------------

class _CareTeamSection extends StatelessWidget {
  const _CareTeamSection({required this.settings, required this.notifier});

  final AppSettings settings;
  final Settings notifier;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: SettingsScreen.careTeamSectionKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Care Circle'),
        _SectionCard(
          child: HoldcloseSwitchListTile(
            key: SettingsScreen.teamCoordinationToggleKey,
            contentPadding: EdgeInsets.zero,
            title: const Text('Coordinate with others'),
            subtitle: const Text(
              "Turn this on if other people help care for your loved one — "
              "it adds a Care Circle to the Care tab for sharing the "
              "schedule, tasks, and expenses. Leave it off if you're "
              "caring on your own.",
            ),
            value: settings.teamCoordinationEnabled,
            onChanged: (bool v) => notifier.setTeamCoordinationEnabled(v),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Your data (Issue #20 — Data Export / Backup) — always visible
// ---------------------------------------------------------------------------

/// Settings card for the full-data backup (Issue #20).
///
/// One action — "Back up my data" — gathers every local record (the loved
/// one, journal, medications + schedule + dose history, appointments +
/// providers, health log, care-plan routines, cards & documents, the care
/// circle, calendar notes, tasks, shifts, expenses, and app settings) into
/// a single machine-readable JSON file and hands it to the OS share sheet
/// so the caregiver can stash it off-device. This is the safety net the
/// doctor-visit PDF (a human-readable summary) isn't: a lost phone no
/// longer means lost data.
///
/// The export runs through [dataExporterProvider] + [exportSourcesProvider]
/// and shares via [dataFileSharerProvider]; the widget test overrides the
/// sharer with a recorder and asserts the row handed off the exporter's
/// bytes.
class _DataSection extends ConsumerStatefulWidget {
  const _DataSection();

  @override
  ConsumerState<_DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends ConsumerState<_DataSection> {
  bool _busy = false;

  Future<void> _backUp() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final DataExporter exporter = ref.read(dataExporterProvider);
      final ExportSources sources = ref.read(exportSourcesProvider);
      final DataFileSharer sharer = ref.read(dataFileSharerProvider);
      await exporter.exportAndShare(sources, sharer);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Backup ready to share.')),
      );
    } catch (error, stack) {
      // Surface the failure to logs so an alpha report can pin the cause
      // (the snackbar stays caregiver-friendly). Previously this swallowed
      // the error entirely, leaving "Back up failed" with no diagnostics.
      debugPrint('Backup failed: $error\n$stack');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Couldn't prepare the backup. Please try again."),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: SettingsScreen.dataSectionKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Your data'),
        _SectionCard(
          child: Column(
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Save everything on this phone — the journal, medications, '
                  'appointments, documents, and the rest — to a single file '
                  'you can keep somewhere safe. If you lose your phone, you '
                  "won't lose your records.",
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12, top: 4),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    key: SettingsScreen.backupDataButtonKey,
                    onPressed: _busy ? null : _backUp,
                    child: Text(_busy ? 'Preparing…' : 'Back up my data'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Demo mode (BUILD_SPEC.md §5.10 + §9.3) — gated by DEMO_MODE
// ---------------------------------------------------------------------------

class _DemoSection extends StatelessWidget {
  const _DemoSection({required this.settings, required this.notifier});

  final AppSettings settings;
  final Settings notifier;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: SettingsScreen.demoSectionKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Demo mode'),
        _SectionCard(
          child: Column(
            children: <Widget>[
              HoldcloseSwitchListTile(
                key: SettingsScreen.resetOnLaunchToggleKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('Reset on launch'),
                subtitle: const Text(
                  'Clears all state every time the app starts. '
                  'Turn off to test the live-app flow.',
                ),
                value: settings.resetOnLaunchDemo,
                onChanged: (bool v) => notifier.setResetOnLaunchDemo(v),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    key: SettingsScreen.reloadSeedButtonKey,
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Seed reloaded.')),
                      );
                    },
                    child: const Text('Reload seed data'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Account (BUILD_SPEC.md §5.10) — gated by NOT DEMO_MODE
// ---------------------------------------------------------------------------

class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthProvider auth = ref.watch(authProvider);
    return Column(
      key: SettingsScreen.accountSectionKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Account'),
        _SectionCard(
          child: Column(
            children: <Widget>[
              StreamBuilder<AuthState>(
                stream: auth.watchAuthState(),
                builder: (BuildContext context,
                    AsyncSnapshot<AuthState> snapshot) {
                  final AuthState? s = snapshot.data;
                  final String email = switch (s) {
                    AuthStateSignedIn(:final User user) => user.email,
                    _ => 'Not signed in',
                  };
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Email'),
                    subtitle: Text(email),
                  );
                },
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    key: SettingsScreen.signOutButtonKey,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: context.cb.error,
                    ),
                    onPressed: () => auth.signOut(),
                    child: const Text('Sign out'),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    key: SettingsScreen.deleteAccountButtonKey,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: context.cb.error,
                      side: BorderSide(color: context.cb.error),
                    ),
                    onPressed: () => _confirmDelete(context, auth),
                    child: const Text('Delete account'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, AuthProvider auth) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This removes the account from this device. The journal entries '
          'and crisis card stay local.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: SettingsScreen.deleteAccountConfirmKey,
            style: TextButton.styleFrom(
              foregroundColor: context.cb.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await auth.deleteAccount();
    }
  }
}

// ---------------------------------------------------------------------------
// About (BUILD_SPEC.md §5.10)
// ---------------------------------------------------------------------------

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  static const String _appVersion = '0.1.0';

  /// A per-build stamp injected via `--dart-define=BUILD_STAMP=...` so a
  /// tester can VERIFY a freshly-pushed build actually landed (the version
  /// name alone never changes). Defaults to 'dev' for un-stamped builds.
  static const String _buildStamp =
      String.fromEnvironment('BUILD_STAMP', defaultValue: 'dev');

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SectionHeader(title: 'About'),
        _SectionCard(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('App version'),
            subtitle: Text('$_appVersion (build $_buildStamp)'),
          ),
        ),
      ],
    );
  }
}

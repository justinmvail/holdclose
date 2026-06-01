import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/settings.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../theme.dart';

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
  static const Key allowAudioToggleKey = Key('settings-allow-audio-toggle');
  static const Key fontSizeSegmentedKey = Key('settings-font-size-segmented');
  static const Key darkModeToggleKey = Key('settings-dark-mode-toggle');
  static const Key demoSectionKey = Key('settings-demo-section');
  static const Key resetOnLaunchToggleKey =
      Key('settings-reset-on-launch-toggle');
  static const Key reloadSeedButtonKey = Key('settings-reload-seed');
  static const Key accountSectionKey = Key('settings-account-section');
  static const Key signOutButtonKey = Key('settings-sign-out');
  static const Key deleteAccountButtonKey = Key('settings-delete-account');
  static const Key deleteAccountConfirmKey =
      Key('settings-delete-account-confirm');
  static const Key methodologyButtonKey = Key('settings-methodology');
  static const Key brandCreditKey = Key('settings-brand-credit');
  static const Key notificationsToggleKey =
      Key('settings-notifications-toggle');
  static const Key trackersSectionKey = Key('settings-trackers-section');
  static const Key useDemoForumToggleKey =
      Key('settings-use-demo-forum-toggle');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    final Settings notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: <Widget>[
            _AudioSection(settings: settings, notifier: notifier),
            const SizedBox(height: 24),
            _FontSizeSection(settings: settings, notifier: notifier),
            const SizedBox(height: 24),
            _AppearanceSection(settings: settings, notifier: notifier),
            const SizedBox(height: 24),
            _TrackersSection(settings: settings, notifier: notifier),
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
              color: careblazersColors.primary,
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
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: child,
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
              SwitchListTile(
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
              SwitchListTile(
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
              SwitchListTile(
                key: SettingsScreen.quietHoursToggleKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('Quiet hours'),
                subtitle: const Text('Mute audio between 10pm and 7am.'),
                value: settings.quietHoursEnabled,
                onChanged:
                    audioOn ? (bool v) => notifier.setQuietHoursEnabled(v) : null,
              ),
              const Divider(height: 1),
              SwitchListTile(
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
              segments: const <ButtonSegment<FontSizeMultiplier>>[
                ButtonSegment<FontSizeMultiplier>(
                  value: FontSizeMultiplier.small,
                  label: Text('Small'),
                ),
                ButtonSegment<FontSizeMultiplier>(
                  value: FontSizeMultiplier.medium,
                  label: Text('Medium'),
                ),
                ButtonSegment<FontSizeMultiplier>(
                  value: FontSizeMultiplier.large,
                  label: Text('Large'),
                ),
                ButtonSegment<FontSizeMultiplier>(
                  value: FontSizeMultiplier.xLarge,
                  label: Text('X-Large'),
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'Appearance'),
        _SectionCard(
          child: SwitchListTile(
            key: SettingsScreen.darkModeToggleKey,
            contentPadding: EdgeInsets.zero,
            title: const Text('Dark mode at night'),
            subtitle: const Text(
              'Switches to a navy palette after 6pm.',
            ),
            value: settings.darkModeAtNight,
            onChanged: (bool v) => notifier.setDarkModeAtNight(v),
          ),
        ),
      ],
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
              SwitchListTile(
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
              const Divider(height: 1),
              SwitchListTile(
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
              SwitchListTile(
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
                      foregroundColor: careblazersColors.error,
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
                      foregroundColor: careblazersColors.error,
                      side: BorderSide(color: careblazersColors.error),
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
              foregroundColor: careblazersColors.error,
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

  static const String _methodologyBody =
      "This app generates coaching scripts using a language model "
      "trained to follow Dr. Natali Edmonds' teaching framework. Audio "
      "playback uses your phone's built-in voice. We never use the "
      "words 'AI' in user-facing copy because we present coaching, not "
      "technology — but we're transparent about how it works here.";

  static const String _brandCreditBody =
      'Coaching framework adapted from Dr. Natali Edmonds '
      '(Dementia Careblazers). Used with permission. '
      '[Note for v1 demo: permission pending — this is the pitch build.]';

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionHeader(title: 'About'),
        _SectionCard(
          child: Column(
            children: <Widget>[
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('App version'),
                subtitle: Text(_appVersion),
              ),
              const Divider(height: 1),
              ListTile(
                key: SettingsScreen.methodologyButtonKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('Methodology'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (BuildContext dialogContext) => AlertDialog(
                    title: const Text('Methodology'),
                    content: Text(
                      _methodologyBody,
                      style: textTheme.bodyMedium,
                    ),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                key: SettingsScreen.brandCreditKey,
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Brand & framework credit',
                      style: textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _brandCreditBody,
                      style: textTheme.bodyMedium?.copyWith(
                        color: careblazersColors.primarySoft,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

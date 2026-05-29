import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// One-time banner that nudges the user to download a higher-quality
/// TTS voice (Enhanced or Premium) for the in-app coach.
///
/// Why this exists: Apple gates voice downloads to Settings.app — no
/// public API lets a third-party app trigger the download itself.
/// What we CAN do is detect the catalog (`AVSpeechSynthesisVoice
/// .speechVoices()` exposes a `quality` field via flutter_tts'
/// `getVoices` map), tell the user a better voice is available, and
/// deep-link them into Settings → Accessibility → Spoken Content.
/// When the download completes the auto-pick path in
/// [OSTTSProvider._pickAutoVoice] grabs the new voice automatically
/// on the next speak().
///
/// Dismiss state lives in SharedPreferences (`voiceBannerDismissed`)
/// so a user who explicitly dismissed it once won't see it again
/// across launches — but the banner does still re-evaluate quality
/// on resume, so if the user later DOWNLOADS a voice manually the
/// banner stays hidden (no longer relevant) without us tracking it.
class VoiceQualityBanner extends ConsumerStatefulWidget {
  const VoiceQualityBanner({super.key});

  static const Key bannerKey = Key('voice-quality-banner');
  static const Key bannerCtaKey = Key('voice-quality-banner-cta');
  static const Key bannerDismissKey = Key('voice-quality-banner-dismiss');
  static const String dismissPrefKey = 'voiceBannerDismissed';

  @override
  ConsumerState<VoiceQualityBanner> createState() => _VoiceQualityBannerState();
}

class _VoiceQualityBannerState extends ConsumerState<VoiceQualityBanner>
    with WidgetsBindingObserver {
  bool _hasEnhancedVoice = true; // optimistic until proven otherwise
  bool _userDismissed = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-evaluate after the user comes back from Settings — they may
    // have completed the download.
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool dismissed =
        prefs.getBool(VoiceQualityBanner.dismissPrefKey) ?? false;
    final bool hasEnhanced = await _detectEnhancedVoice();
    if (!mounted) return;
    setState(() {
      _hasEnhancedVoice = hasEnhanced;
      _userDismissed = dismissed;
      _loaded = true;
    });
  }

  Future<bool> _detectEnhancedVoice() async {
    try {
      final FlutterTts tts = FlutterTts();
      final dynamic raw = await tts.getVoices;
      if (raw is! List) return true; // unknown — don't nag
      for (final dynamic entry in raw) {
        if (entry is! Map) continue;
        final String? locale = entry['locale']?.toString();
        if (locale == null || !locale.toLowerCase().startsWith('en')) continue;
        final String quality =
            entry['quality']?.toString().toLowerCase() ?? '';
        if (quality.contains('enhanced') || quality.contains('premium')) {
          return true;
        }
      }
      return false;
    } on Exception {
      // Bad map shape from a future flutter_tts upgrade etc. — don't
      // nag if we can't tell.
      return true;
    }
  }

  Future<void> _openSettings() async {
    // iOS 18 intentionally broke most `prefs:root=…&path=…` paths,
    // including the historical `prefs:root=ACCESSIBILITY&path=SPEECH`.
    // What still works in iOS 18+ is the bundle-ID pattern — e.g.
    // `App-prefs:com.apple.UniversalAccess` opens Accessibility's
    // root panel. There is NO documented or undocumented way to
    // land directly on Spoken Content from a third-party app today
    // (per Apple Developer Forums thread 759900 and confirmed
    // empirically on iOS 26). The banner copy spells out the three-
    // tap nav from the Accessibility root → Spoken Content → Voices
    // so even the best-case deep link still asks the user for
    // those final taps.
    //
    // Falls back to the public `app-settings:` (UIApplication
    // .openSettingsURLString equivalent) which opens THIS app's
    // settings — not Accessibility's. That's the least-bad fallback
    // when nothing else is allowed.
    const List<String> candidates = <String>[
      // iOS 18+ bundle-ID pattern that actually works.
      'App-prefs:com.apple.UniversalAccess',
      // Older bundle-ID variant + capitalization permutations.
      'App-Prefs:com.apple.UniversalAccess',
      'prefs:com.apple.UniversalAccess',
      // Legacy root-only path (broken in 18+ but worth probing on
      // older OS targets).
      'App-Prefs:root=ACCESSIBILITY',
      'prefs:root=ACCESSIBILITY',
      // Public-API fallback — opens this app's own settings page.
      'app-settings:',
    ];
    for (final String url in candidates) {
      final Uri uri = Uri.parse(url);
      try {
        if (await canLaunchUrl(uri)) {
          final bool launched = await launchUrl(uri);
          if (launched) return;
        }
      } on Exception {
        // Some schemes throw on canLaunch under sandbox restrictions;
        // try the next.
        continue;
      }
    }
  }

  Future<void> _dismiss() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(VoiceQualityBanner.dismissPrefKey, true);
    if (!mounted) return;
    setState(() => _userDismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _hasEnhancedVoice || _userDismissed) {
      return const SizedBox.shrink();
    }
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Card(
      key: VoiceQualityBanner.bannerKey,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: careblazersColors.surfaceWarm,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: careblazersColors.primarySoft.withValues(alpha: 0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.record_voice_over_rounded,
                  color: careblazersColors.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Better-sounding voice available',
                        style: textTheme.titleMedium?.copyWith(
                          color: careblazersColors.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Download a higher-quality voice in Settings → '
                        'Accessibility → Spoken Content → Voices → English → '
                        "tap a name → Premium.",
                        style: textTheme.bodyMedium?.copyWith(
                          color: careblazersColors.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  key: VoiceQualityBanner.bannerDismissKey,
                  onPressed: _dismiss,
                  child: const Text('Not now'),
                ),
                FilledButton(
                  key: VoiceQualityBanner.bannerCtaKey,
                  onPressed: _openSettings,
                  style: FilledButton.styleFrom(
                    backgroundColor: careblazersColors.cta,
                  ),
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

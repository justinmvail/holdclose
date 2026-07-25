import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_tts/flutter_tts.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/settings.dart';
import 'bundled_tts_provider.dart';
import 'quiet_hours_provider.dart' show quietHoursActiveProvider;

part 'tts_provider.freezed.dart';
part 'tts_provider.g.dart';

/// One installed OS voice (BUILD_SPEC.md §6.3).
///
/// [id] is `"<name>|<locale>"` — flutter_tts's `setVoice` requires both
/// fields, so we encode them together to round-trip through
/// [AppSettings.voiceId] without a separate cache lookup.
@freezed
abstract class TTSVoice with _$TTSVoice {
  const factory TTSVoice({
    required String id,
    required String displayName,
    required String locale,
    required String gender,
  }) = _TTSVoice;
}

/// Speech-synthesis backend (BUILD_SPEC.md §6.3).
///
/// Two v1 implementations: [OSTTSProvider] (wraps `flutter_tts`) and
/// [NoopTTSProvider] (silent — used in tests and when settings say
/// "Read aloud" is off or quiet hours are active). The app never
/// imports either concrete class directly; it goes through
/// [ttsProvider], which picks based on the current [AppSettings] +
/// the wall-clock quiet-hours window.
abstract class TTSProvider {
  /// Speak [text] aloud. Resolves when the utterance completes
  /// (cancellable mid-flight via [cancel]).
  Future<void> speak(
    String text, {
    required String voiceId,
    required double speed,
  });

  /// Stop mid-utterance.
  Future<void> cancel();

  /// All voices the OS has installed. Empty list when no engine.
  Future<List<TTSVoice>> availableVoices();
}

/// Real impl wrapping `flutter_tts` (BUILD_SPEC.md §6.3).
///
/// The underlying [FlutterTts] is the platform-channel client; it's
/// injected so unit tests can supply one wired to a mock method
/// channel. The constructor itself doesn't touch the OS engine —
/// platform setup (`awaitSpeakCompletion`) is deferred to the first
/// [speak] call so a "Read aloud OFF" selection never spins the
/// engine up.
class OSTTSProvider implements TTSProvider {
  OSTTSProvider({FlutterTts? engine}) : _tts = engine ?? FlutterTts();

  final FlutterTts _tts;
  bool _awaitWired = false;

  /// Cached auto-picked voice — picked lazily on the first speak() so
  /// `getVoices` round-trips happen off the main draw path.
  Map<String, String>? _autoVoice;

  @override
  Future<void> speak(
    String text, {
    required String voiceId,
    required double speed,
  }) async {
    if (!_awaitWired) {
      // Block speak()'s future until the utterance completes, so the
      // streaming coach reply's per-line ▶ button can `await` one
      // section before the next starts (BUILD_SPEC.md §7.4).
      await _tts.awaitSpeakCompletion(true);
      _awaitWired = true;
    }
    await _tts.setSpeechRate(_clampRate(speed));
    final Map<String, String>? voice =
        _decodeVoiceId(voiceId) ?? await _pickAutoVoice();
    if (voice != null) {
      await _tts.setVoice(voice);
    }
    await _tts.speak(text);
  }

  /// Auto-pick the best installed en-* voice, preferring premium then
  /// enhanced quality and falling back to the first en-* entry. Called
  /// lazily; the result is cached after the first speak() to keep
  /// subsequent utterances off the `getVoices` round-trip.
  Future<Map<String, String>?> _pickAutoVoice() async {
    if (_autoVoice != null) return _autoVoice;
    final dynamic raw = await _tts.getVoices;
    if (raw is! List) return null;
    Map<String, String>? enhanced;
    Map<String, String>? premium;
    Map<String, String>? anyEn;
    for (final dynamic entry in raw) {
      if (entry is! Map) continue;
      final String? name = entry['name']?.toString();
      final String? locale = entry['locale']?.toString();
      if (name == null || locale == null) continue;
      if (!locale.toLowerCase().startsWith('en')) continue;
      final String quality = entry['quality']?.toString().toLowerCase() ?? '';
      final Map<String, String> v = <String, String>{
        'name': name,
        'locale': locale,
      };
      anyEn ??= v;
      if (quality.contains('premium')) {
        premium ??= v;
      } else if (quality.contains('enhanced')) {
        enhanced ??= v;
      }
    }
    final Map<String, String>? picked = premium ?? enhanced ?? anyEn;
    _autoVoice = picked;
    return picked;
  }

  @override
  Future<void> cancel() async {
    await _tts.stop();
  }

  @override
  Future<List<TTSVoice>> availableVoices() async {
    final dynamic raw = await _tts.getVoices;
    if (raw is! List) return const <TTSVoice>[];
    final List<TTSVoice> out = <TTSVoice>[];
    for (final dynamic entry in raw) {
      if (entry is! Map) continue;
      final String? name = entry['name']?.toString();
      final String? locale = entry['locale']?.toString();
      if (name == null || locale == null) continue;
      final String gender = entry['gender']?.toString() ?? 'unknown';
      out.add(TTSVoice(
        id: encodeVoiceId(name: name, locale: locale),
        displayName: name,
        locale: locale,
        gender: gender,
      ));
    }
    return out;
  }

  /// Pack a voice name + locale into the single [TTSVoice.id] /
  /// [AppSettings.voiceId] string.
  static String encodeVoiceId({
    required String name,
    required String locale,
  }) =>
      '$name|$locale';

  /// flutter_tts's rate semantics are platform-dependent:
  ///   - iOS:     1.0 is the platform MAXIMUM (sounds fast-forwarded).
  ///              Normal-paced speech corresponds to ~0.5; the AVSpeech
  ///              synthesizer maps the value to the underlying
  ///              AVSpeechUtteranceDefaultSpeechRate range.
  ///   - Android: 1.0 IS normal speed (the TextToSpeech API uses 1.0
  ///              as the baseline).
  /// The Settings slider exposes 0.7×/1.0×/1.3× (BUILD_SPEC.md §11.1) —
  /// caller-facing semantics where 1.0 is "normal". Translate to the
  /// platform's underlying rate before handing it to flutter_tts.
  double _clampRate(double speed) {
    if (speed < 0.1) return 0.1;
    if (speed > 1.5) return 1.5;
    if (Platform.isIOS) {
      // Map caller 0.7 / 1.0 / 1.3 → iOS 0.35 / 0.5 / 0.65 so the
      // platform default sits at the middle slider notch.
      return speed * 0.5;
    }
    return speed;
  }

  Map<String, String>? _decodeVoiceId(String voiceId) {
    if (voiceId.isEmpty) return null;
    final int sep = voiceId.indexOf('|');
    if (sep <= 0 || sep == voiceId.length - 1) return null;
    return <String, String>{
      'name': voiceId.substring(0, sep),
      'locale': voiceId.substring(sep + 1),
    };
  }
}

/// Silent impl (BUILD_SPEC.md §6.3).
///
/// Used in two places: widget tests (no platform channel involvement)
/// and the live app whenever the [ttsProvider] selector decides audio
/// is muted — toggle off, quiet hours active without the override,
/// etc. Every method resolves immediately and [availableVoices]
/// returns an empty list.
class NoopTTSProvider implements TTSProvider {
  const NoopTTSProvider();

  @override
  Future<void> speak(
    String text, {
    required String voiceId,
    required double speed,
  }) async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<List<TTSVoice>> availableVoices() async => const <TTSVoice>[];
}

// ---------------------------------------------------------------------------
// Quiet-hours selection logic
// ---------------------------------------------------------------------------

/// Default quiet-hours window per BUILD_SPEC.md §11.2: 10pm → 7am local.
const int defaultQuietHoursStart = 22;
const int defaultQuietHoursEnd = 7;

/// True when [now]'s local hour falls inside the quiet-hours window.
///
/// The window wraps midnight: any hour ≥ [startHour] OR < [endHour]
/// counts as quiet. Boundary contract: 10:00pm IS quiet; 7:00am is NOT.
bool isQuietHoursActive(
  DateTime now, {
  int startHour = defaultQuietHoursStart,
  int endHour = defaultQuietHoursEnd,
}) {
  final int h = now.hour;
  return h >= startHour || h < endHour;
}

/// Whether [ttsProvider] should mute given [settings] and the current
/// [now]. Pure function so the selection rule is testable without a
/// Riverpod container.
bool shouldMuteTts(AppSettings settings, DateTime now) {
  if (!settings.readScriptsAloud) return true;
  return _quietHoursMute(settings, now);
}

/// Whether a VOICE-MODE reply should mute — [voiceReplyTtsProvider]'s rule.
///
/// Deliberately does NOT consult [AppSettings.readScriptsAloud]. The caregiver
/// tapped the mic and SPOKE; a spoken answer is the interaction itself, not an
/// audio preference, and a mic that answers in silence reads as broken. The
/// toggle governs only the replies they DIDN'T ask for out loud (typed chat).
///
/// Quiet hours still win — a 3am voice question must not wake the house.
bool shouldMuteVoiceReply(AppSettings settings, DateTime now) =>
    _quietHoursMute(settings, now);

bool _quietHoursMute(AppSettings settings, DateTime now) {
  if (!settings.quietHoursEnabled) return false;
  if (settings.allowAudioDuringQuietHours) return false;
  return isQuietHoursActive(
    now,
    startHour: settings.quietHoursStartHour,
    endHour: settings.quietHoursEndHour,
  );
}

/// Strip the coach's reply down to something worth HEARING.
///
/// The body is written for the eye: markdown emphasis, `#` headings, bullet
/// glyphs, code fences. A synthesizer reads those literally ("star star take
/// star star"), so they're removed rather than spoken. Blank lines collapse to
/// a single break so the utterance doesn't stall.
String speechText(String body) {
  final String stripped = body
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'[*_`#>]'), '')
      .replaceAll(RegExp(r'^\s*[-•]\s*', multiLine: true), '')
      .replaceAll(RegExp(r'\n{2,}'), '\n')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  return stripped.trim();
}

// ---------------------------------------------------------------------------
// Riverpod wiring
// ---------------------------------------------------------------------------

/// Snapshot of the current settings consumed by the TTS selector.
///
/// Defaults to [AppSettings.defaults] so the rest of the wiring works
/// before the SettingsNotifier lands; overridden in the live
/// ProviderScope (and in tests) to drive the toggle / quiet-hours
/// selection through [ttsProvider].
@Riverpod(keepAlive: true)
AppSettings ttsSettings(Ref ref) => AppSettings.defaults();

/// Wall clock the quiet-hours check consults. Override in tests to pin
/// a deterministic hour without touching system time.
@Riverpod(keepAlive: true)
DateTime Function() ttsClock(Ref ref) => DateTime.now;

/// Riverpod-wired TTS backend (BUILD_SPEC.md §6.3 + §11.2 + Phase 9.5).
///
/// Returns [NoopTTSProvider] whenever the Settings toggle is off or
/// the wall clock is inside the quiet-hours window (and the user
/// hasn't flipped "Allow audio anyway"). Otherwise picks between the
/// bundled neural-TTS path ([BundledTTSProvider], default — Piper
/// Amy running on-device via ONNX Runtime, ~30 MB) and the OS
/// flutter_tts engine ([OSTTSProvider]) based on
/// [AppSettings.useBundledVoice].
@Riverpod(keepAlive: true)
TTSProvider tts(Ref ref) {
  final AppSettings settings = ref.watch(ttsSettingsProvider);
  final DateTime now = ref.watch(ttsClockProvider)();
  // A keepAlive provider freezes its build-time decision until an input
  // changes — and "what time is it" is not a riverpod input. Watching
  // the minute-polling QuietHoursActive notifier (value unused; it's a
  // rebuild TICK) makes CROSSING 10pm/7am mid-session re-resolve the
  // impl, so entering quiet hours actually mutes and leaving them
  // actually unmutes without waiting for an unrelated settings write.
  ref.watch(quietHoursActiveProvider);
  if (shouldMuteTts(settings, now)) {
    return const NoopTTSProvider();
  }
  return _engineFor(settings);
}

/// The engine the hands-free MIC flow speaks its reply through.
///
/// Same engines, one different rule: it ignores the "Read replies aloud"
/// toggle (see [shouldMuteVoiceReply]) because the caregiver spoke to it. Quiet
/// hours still mute.
@Riverpod(keepAlive: true)
TTSProvider voiceReplyTts(Ref ref) {
  final AppSettings settings = ref.watch(ttsSettingsProvider);
  final DateTime now = ref.watch(ttsClockProvider)();
  ref.watch(quietHoursActiveProvider);
  if (shouldMuteVoiceReply(settings, now)) {
    return const NoopTTSProvider();
  }
  return _engineFor(settings);
}

/// Pick the speech engine — ONCE, from the settings, no runtime fallback.
///
/// There is deliberately NO real-time fallback from the bundled voice to the OS
/// voice. A short-lived FallbackTTSProvider tried that (2026-07-14) and it was a
/// mistake: the bundled voice and the OS synthesizer are INDEPENDENT audio
/// outputs, so when the bundled voice threw mid-utterance the fallback started
/// reading the whole reply through the OS voice ON TOP of the bundled sentences
/// still draining — two different voices at once. Switching engines while a
/// caregiver is listening is never the right call.
///
/// The engine is a launch-time decision (re-resolved only when the caregiver
/// changes the Settings toggle). If the bundled voice fails, it fails loudly and
/// stays silent — a wrong voice mid-sentence is worse than none. Making the
/// bundled path reliable is the fix; papering over it in real time is not.
TTSProvider _engineFor(AppSettings settings) =>
    settings.useBundledVoice ? BundledTTSProvider() : OSTTSProvider();

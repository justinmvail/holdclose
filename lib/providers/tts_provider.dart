import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/settings.dart';

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

  @override
  Future<void> speak(
    String text, {
    required String voiceId,
    required double speed,
  }) async {
    if (!_awaitWired) {
      // Block speak()'s future until the utterance completes, so the
      // decoder result screen's per-line ▶ button can `await` one
      // section before the next starts (BUILD_SPEC.md §7.4).
      await _tts.awaitSpeakCompletion(true);
      _awaitWired = true;
    }
    await _tts.setSpeechRate(_clampRate(speed));
    final Map<String, String>? voice = _decodeVoiceId(voiceId);
    if (voice != null) {
      await _tts.setVoice(voice);
    }
    await _tts.speak(text);
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

  /// flutter_tts on iOS clamps speech rate to roughly [0.0, 1.0].
  /// The Settings slider exposes 0.7×/1.0×/1.3× (BUILD_SPEC.md §11.1).
  /// Bound the input so an out-of-range multiplier from a stale build
  /// doesn't reject the speak() call.
  double _clampRate(double speed) {
    if (speed < 0.1) return 0.1;
    if (speed > 1.5) return 1.5;
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
  if (!settings.quietHoursEnabled) return false;
  if (settings.allowAudioDuringQuietHours) return false;
  return isQuietHoursActive(now);
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

/// Riverpod-wired TTS backend (BUILD_SPEC.md §6.3 + §11.2).
///
/// Returns [NoopTTSProvider] whenever the Settings toggle is off or
/// the wall clock is inside the quiet-hours window (and the user
/// hasn't flipped "Allow audio anyway"). Otherwise returns a fresh
/// [OSTTSProvider] — the constructor is cheap and doesn't touch the
/// platform engine until [TTSProvider.speak] runs.
@Riverpod(keepAlive: true)
TTSProvider tts(Ref ref) {
  final AppSettings settings = ref.watch(ttsSettingsProvider);
  final DateTime now = ref.watch(ttsClockProvider)();
  if (shouldMuteTts(settings, now)) {
    return const NoopTTSProvider();
  }
  return OSTTSProvider();
}

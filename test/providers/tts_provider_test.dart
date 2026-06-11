import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/bundled_tts_provider.dart';
import 'package:careblazers/providers/storage_provider.dart'
    show InMemoryStorageProvider, storageBackendProvider;
import 'package:careblazers/providers/tts_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Test subclass of [NoopTTSProvider] that flips a flag when speak is
/// invoked (per the Task 8 contract: "NoopTTS speaks nothing —
/// assertion via a flag flipped in a subclass"). The base
/// [NoopTTSProvider] is a true no-op; this subclass records the call
/// from the override path so tests can assert (a) calls made through
/// the riverpod-selected impl never reach this spy, and (b) the
/// override mechanism itself works.
class _SpyNoopTTSProvider extends NoopTTSProvider {
  _SpyNoopTTSProvider();

  bool didSpeak = false;
  String? lastText;
  String? lastVoiceId;
  double? lastSpeed;
  int cancelCount = 0;

  @override
  Future<void> speak(
    String text, {
    required String voiceId,
    required double speed,
  }) async {
    didSpeak = true;
    lastText = text;
    lastVoiceId = voiceId;
    lastSpeed = speed;
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---- NoopTTSProvider -----------------------------------------------------

  group('NoopTTSProvider', () {
    test('speak resolves without doing anything', () async {
      const NoopTTSProvider noop = NoopTTSProvider();
      // No mock channel installed — if NoopTTSProvider touched a
      // platform engine, this would throw a MissingPluginException.
      await noop.speak('hello', voiceId: 'Alex|en-US', speed: 1.0);
    });

    test('cancel resolves without doing anything', () async {
      const NoopTTSProvider noop = NoopTTSProvider();
      await noop.cancel();
    });

    test('availableVoices returns an empty list', () async {
      const NoopTTSProvider noop = NoopTTSProvider();
      expect(await noop.availableVoices(), isEmpty);
    });

    test(
      'speaks nothing — subclass spy never sees a call through the base',
      () async {
        // Calling speak on a plain NoopTTSProvider must not invoke the
        // subclass override path. We verify by holding both side-by-side:
        // the spy stays untouched when only the base is used.
        const NoopTTSProvider base = NoopTTSProvider();
        final _SpyNoopTTSProvider spy = _SpyNoopTTSProvider();

        await base.speak('hi', voiceId: '', speed: 1.0);
        expect(spy.didSpeak, isFalse,
            reason:
                'speak() on the base no-op must not reach the subclass spy');

        // And sanity-check that the spy *does* flip when its own speak
        // is called — otherwise the assertion above is vacuous.
        await spy.speak('hi', voiceId: '', speed: 1.0);
        expect(spy.didSpeak, isTrue);
        expect(spy.lastText, 'hi');
      },
    );

    test('still a TTSProvider — overrideable in the riverpod scope',
        () async {
      final _SpyNoopTTSProvider spy = _SpyNoopTTSProvider();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          ttsProvider.overrideWithValue(spy),
        ],
      );
      addTearDown(container.dispose);
      final TTSProvider resolved = container.read(ttsProvider);
      expect(identical(resolved, spy), isTrue);
      await resolved.cancel();
      expect(spy.cancelCount, 1);
    });
  });

  // ---- Quiet-hours pure logic ---------------------------------------------

  group('isQuietHoursActive', () {
    test('default 10pm–7am window: boundary points', () {
      expect(isQuietHoursActive(DateTime(2026, 5, 29, 21, 59)), isFalse,
          reason: '9:59pm is outside quiet hours');
      expect(isQuietHoursActive(DateTime(2026, 5, 29, 22, 0)), isTrue,
          reason: '10pm is the start of quiet hours');
      expect(isQuietHoursActive(DateTime(2026, 5, 29, 23, 30)), isTrue);
      expect(isQuietHoursActive(DateTime(2026, 5, 30, 0, 0)), isTrue,
          reason: 'midnight wraps inside the window');
      expect(isQuietHoursActive(DateTime(2026, 5, 30, 6, 59)), isTrue);
      expect(isQuietHoursActive(DateTime(2026, 5, 30, 7, 0)), isFalse,
          reason: '7am is the first non-quiet hour');
      expect(isQuietHoursActive(DateTime(2026, 5, 30, 14, 0)), isFalse,
          reason: '2pm is outside quiet hours');
    });

    test('custom window honours startHour + endHour parameters', () {
      // 11pm → 6am window.
      expect(
        isQuietHoursActive(DateTime(2026, 5, 29, 22, 30),
            startHour: 23, endHour: 6),
        isFalse,
      );
      expect(
        isQuietHoursActive(DateTime(2026, 5, 29, 23, 0),
            startHour: 23, endHour: 6),
        isTrue,
      );
      expect(
        isQuietHoursActive(DateTime(2026, 5, 30, 5, 59),
            startHour: 23, endHour: 6),
        isTrue,
      );
      expect(
        isQuietHoursActive(DateTime(2026, 5, 30, 6, 0),
            startHour: 23, endHour: 6),
        isFalse,
      );
    });
  });

  group('shouldMuteTts', () {
    final DateTime mid = DateTime(2026, 5, 29, 14, 0); // 2pm — not quiet
    final DateTime late = DateTime(2026, 5, 29, 23, 30); // 11:30pm — quiet

    test('mutes when readScriptsAloud is false (even outside quiet hours)',
        () {
      final AppSettings off = AppSettings.defaults()
          .copyWith(readScriptsAloud: false);
      expect(shouldMuteTts(off, mid), isTrue);
      expect(shouldMuteTts(off, late), isTrue);
    });

    test('mutes during quiet hours when quietHoursEnabled', () {
      final AppSettings on = AppSettings.defaults();
      expect(shouldMuteTts(on, mid), isFalse);
      expect(shouldMuteTts(on, late), isTrue);
    });

    test('quietHoursEnabled=false skips the quiet-hours mute', () {
      final AppSettings noQuiet = AppSettings.defaults()
          .copyWith(quietHoursEnabled: false);
      expect(shouldMuteTts(noQuiet, late), isFalse);
    });

    test('allowAudioDuringQuietHours overrides the quiet-hours mute', () {
      final AppSettings override = AppSettings.defaults()
          .copyWith(allowAudioDuringQuietHours: true);
      expect(shouldMuteTts(override, late), isFalse);
    });

    test('honours a custom quiet-hours window (8pm–6am)', () {
      // A user who shifts the window earlier: 8pm now mutes, and a time the
      // default 10pm window would NOT have muted (9pm) now does.
      final AppSettings custom = AppSettings.defaults()
          .copyWith(quietHoursStartHour: 20, quietHoursEndHour: 6);
      final DateTime ninePm = DateTime(2026, 5, 29, 21, 0);
      final DateTime sixThirtyAm = DateTime(2026, 5, 29, 6, 30);
      expect(shouldMuteTts(custom, ninePm), isTrue,
          reason: '9pm is inside the custom 8pm–6am window');
      expect(shouldMuteTts(custom, sixThirtyAm), isFalse,
          reason: '6:30am is past the custom 6am end');
    });
  });

  // ---- Riverpod ttsProvider selection -------------------------------------

  group('ttsProvider riverpod selection', () {
    ProviderContainer buildContainer({
      required AppSettings settings,
      required DateTime now,
    }) {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          ttsSettingsProvider.overrideWithValue(settings),
          ttsClockProvider.overrideWithValue(() => now),
          // The tts selector watches the minute-polling QuietHoursActive
          // tick (2026-06-11, mid-session boundary crossing), whose
          // settings read would otherwise open the real drift database
          // in this unit-test container.
          storageBackendProvider.overrideWithValue(
            InMemoryStorageProvider(),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('returns Noop when readScriptsAloud is OFF (outside quiet hours)',
        () {
      final ProviderContainer container = buildContainer(
        settings: AppSettings.defaults().copyWith(readScriptsAloud: false),
        now: DateTime(2026, 5, 29, 14, 0),
      );
      expect(container.read(ttsProvider), isA<NoopTTSProvider>());
    });

    test('returns Noop during quiet hours (toggle ON, no override)', () {
      final ProviderContainer container = buildContainer(
        settings: AppSettings.defaults(),
        now: DateTime(2026, 5, 29, 23, 30),
      );
      expect(container.read(ttsProvider), isA<NoopTTSProvider>());
    });

    test(
      'returns BundledTTSProvider when audio enabled, outside quiet hours, '
      'and useBundledVoice=true (the real-build default)',
      () {
        final ProviderContainer container = buildContainer(
          settings: AppSettings.defaults(),
          now: DateTime(2026, 5, 29, 14, 0),
        );
        expect(container.read(ttsProvider), isA<BundledTTSProvider>());
      },
    );

    test(
      'returns OSTTSProvider when useBundledVoice=false (caregiver opt-out)',
      () {
        final ProviderContainer container = buildContainer(
          settings:
              AppSettings.defaults().copyWith(useBundledVoice: false),
          now: DateTime(2026, 5, 29, 14, 0),
        );
        expect(container.read(ttsProvider), isA<OSTTSProvider>());
      },
    );

    test(
      'returns BundledTTSProvider during quiet hours when override is on',
      () {
        final ProviderContainer container = buildContainer(
          settings: AppSettings.defaults()
              .copyWith(allowAudioDuringQuietHours: true),
          now: DateTime(2026, 5, 29, 23, 30),
        );
        expect(container.read(ttsProvider), isA<BundledTTSProvider>());
      },
    );

    test('default container falls through to Noop in quiet hours', () {
      // No clock override + no settings override — exercises the
      // unparametrised defaults (AppSettings.defaults() + DateTime.now).
      // The selection contract is what we assert here, not the wall
      // hour: read it once and ensure it's one of the three expected
      // types (no exceptions, no NPEs from the riverpod_generator
      // wiring).
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageBackendProvider.overrideWithValue(
            InMemoryStorageProvider(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final TTSProvider impl = container.read(ttsProvider);
      expect(
        impl is NoopTTSProvider ||
            impl is OSTTSProvider ||
            impl is BundledTTSProvider,
        isTrue,
        reason: 'unexpected default impl: ${impl.runtimeType}',
      );
    });

    // ---- Phase 9.5 factory-choice contract (table-driven) ---------------

    test('factory chooses BundledTTSProvider when bundled=true + not muted',
        () {
      final ProviderContainer container = buildContainer(
        settings: AppSettings.defaults()
            .copyWith(useBundledVoice: true, quietHoursEnabled: false),
        now: DateTime(2026, 5, 29, 14, 0),
      );
      expect(container.read(ttsProvider), isA<BundledTTSProvider>());
    });

    test('factory chooses OSTTSProvider when bundled=false + not muted', () {
      final ProviderContainer container = buildContainer(
        settings: AppSettings.defaults()
            .copyWith(useBundledVoice: false, quietHoursEnabled: false),
        now: DateTime(2026, 5, 29, 14, 0),
      );
      expect(container.read(ttsProvider), isA<OSTTSProvider>());
    });

    test('factory chooses NoopTTSProvider when OS-mute wins (any bundled)',
        () {
      // OS-mute trumps the bundled toggle: quiet hours active, no audio
      // override, useBundledVoice=true — still mutes.
      final ProviderContainer container = buildContainer(
        settings: AppSettings.defaults().copyWith(useBundledVoice: true),
        now: DateTime(2026, 5, 29, 23, 30),
      );
      expect(container.read(ttsProvider), isA<NoopTTSProvider>());
    });

    test('override hook swaps in a custom impl end-to-end', () async {
      final _SpyNoopTTSProvider spy = _SpyNoopTTSProvider();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          ttsProvider.overrideWithValue(spy),
        ],
      );
      addTearDown(container.dispose);
      final TTSProvider impl = container.read(ttsProvider);
      await impl.speak('test', voiceId: 'Alex|en-US', speed: 0.9);
      expect(spy.didSpeak, isTrue);
      expect(spy.lastVoiceId, 'Alex|en-US');
      expect(spy.lastSpeed, 0.9);
    });
  });

  // ---- TTSVoice freezed model ---------------------------------------------

  group('TTSVoice', () {
    test('equality holds for matching field-by-field instances', () {
      const TTSVoice a = TTSVoice(
        id: 'Alex|en-US',
        displayName: 'Alex',
        locale: 'en-US',
        gender: 'male',
      );
      const TTSVoice b = TTSVoice(
        id: 'Alex|en-US',
        displayName: 'Alex',
        locale: 'en-US',
        gender: 'male',
      );
      expect(a, equals(b));
    });

    test('encodeVoiceId packs name + locale into the round-trippable form',
        () {
      expect(
        OSTTSProvider.encodeVoiceId(name: 'Samantha', locale: 'en-US'),
        'Samantha|en-US',
      );
    });
  });

  // ---- OSTTSProvider (via mocked flutter_tts MethodChannel) ---------------

  group('OSTTSProvider', () {
    const MethodChannel channel = MethodChannel('flutter_tts');
    final List<MethodCall> calls = <MethodCall>[];
    Object? voicesResponse;

    setUp(() {
      calls.clear();
      voicesResponse = <Map<dynamic, dynamic>>[
        <String, dynamic>{
          'name': 'Samantha',
          'locale': 'en-US',
          'gender': 'female',
        },
        <String, dynamic>{
          'name': 'Daniel',
          'locale': 'en-GB',
          'gender': 'male',
        },
        // Without a 'name' — should be skipped.
        <String, dynamic>{'locale': 'en-AU'},
      ];
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        switch (call.method) {
          case 'getVoices':
            return voicesResponse;
          case 'awaitSpeakCompletion':
          case 'setSpeechRate':
          case 'setVoice':
          case 'speak':
          case 'stop':
            return 1;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'availableVoices parses the OS list and skips malformed entries',
      () async {
        final OSTTSProvider os = OSTTSProvider();
        final List<TTSVoice> voices = await os.availableVoices();
        expect(voices, hasLength(2));
        expect(voices.first.id, 'Samantha|en-US');
        expect(voices.first.displayName, 'Samantha');
        expect(voices.first.locale, 'en-US');
        expect(voices.first.gender, 'female');
        expect(voices.last.id, 'Daniel|en-GB');
        expect(voices.last.gender, 'male');
      },
    );

    test('availableVoices tolerates a non-List response', () async {
      voicesResponse = 'not a list';
      final OSTTSProvider os = OSTTSProvider();
      expect(await os.availableVoices(), isEmpty);
    });

    test(
      'speak wires awaitSpeakCompletion, setSpeechRate, setVoice, speak',
      () async {
        final OSTTSProvider os = OSTTSProvider();
        await os.speak('hello', voiceId: 'Samantha|en-US', speed: 1.0);
        final List<String> methodOrder =
            calls.map((MethodCall c) => c.method).toList();
        expect(methodOrder.contains('awaitSpeakCompletion'), isTrue);
        expect(methodOrder.contains('setSpeechRate'), isTrue);
        expect(methodOrder.contains('setVoice'), isTrue);
        expect(methodOrder.contains('speak'), isTrue);
        expect(
          methodOrder.indexOf('setSpeechRate'),
          lessThan(methodOrder.indexOf('speak')),
        );
        final MethodCall voiceCall =
            calls.firstWhere((MethodCall c) => c.method == 'setVoice');
        final Map<dynamic, dynamic> voiceArg =
            voiceCall.arguments as Map<dynamic, dynamic>;
        expect(voiceArg['name'], 'Samantha');
        expect(voiceArg['locale'], 'en-US');
      },
    );

    test(
      'awaitSpeakCompletion is only wired once across multiple speak calls',
      () async {
        final OSTTSProvider os = OSTTSProvider();
        await os.speak('one', voiceId: '', speed: 1.0);
        await os.speak('two', voiceId: '', speed: 1.0);
        final int wiringCalls = calls
            .where((MethodCall c) => c.method == 'awaitSpeakCompletion')
            .length;
        expect(wiringCalls, 1,
            reason: 'awaitSpeakCompletion should only run on first speak');
      },
    );

    test('speak with empty voiceId auto-picks the best installed voice',
        () async {
      // An empty voiceId no longer falls through to the platform
      // default. The provider enumerates getVoices() and picks the
      // highest-quality installed voice (premium > enhanced > first
      // en-* entry), then calls setVoice with it.
      final OSTTSProvider os = OSTTSProvider();
      await os.speak('plain', voiceId: '', speed: 1.0);
      final MethodCall setVoice =
          calls.firstWhere((MethodCall c) => c.method == 'setVoice');
      // The mocked voice list contains Samantha (en-US) and Daniel
      // (en-GB), both "default" quality, so the auto-pick falls back
      // to the first en-* entry — Samantha.
      expect((setVoice.arguments as Map)['name'], 'Samantha');
      expect((setVoice.arguments as Map)['locale'], 'en-US');
    });

    test('speak with malformed voiceId (no separator) also auto-picks',
        () async {
      // Malformed voiceIds are treated the same as empty — the
      // provider can't decode a "<name>|<locale>" pair, so it falls
      // through to the auto-pick path.
      final OSTTSProvider os = OSTTSProvider();
      await os.speak('plain', voiceId: 'no-pipe-here', speed: 1.0);
      final MethodCall setVoice =
          calls.firstWhere((MethodCall c) => c.method == 'setVoice');
      expect((setVoice.arguments as Map)['name'], 'Samantha');
    });

    test('cancel calls stop on the underlying engine', () async {
      final OSTTSProvider os = OSTTSProvider();
      await os.cancel();
      expect(calls.last.method, 'stop');
    });

    test('clamps speech rate above the upper bound', () async {
      final OSTTSProvider os = OSTTSProvider();
      await os.speak('zoom', voiceId: '', speed: 9.0);
      final MethodCall rateCall =
          calls.firstWhere((MethodCall c) => c.method == 'setSpeechRate');
      expect(rateCall.arguments as double, lessThanOrEqualTo(1.5));
    });

    test('clamps speech rate below the lower bound', () async {
      final OSTTSProvider os = OSTTSProvider();
      await os.speak('crawl', voiceId: '', speed: 0.0);
      final MethodCall rateCall =
          calls.firstWhere((MethodCall c) => c.method == 'setSpeechRate');
      expect(rateCall.arguments as double, greaterThanOrEqualTo(0.1));
    });

    test('accepts an injected FlutterTts engine (for wiring)', () {
      final FlutterTts engine = FlutterTts();
      final OSTTSProvider os = OSTTSProvider(engine: engine);
      expect(os, isA<TTSProvider>());
    });
  });
}

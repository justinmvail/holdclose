import 'package:careblazers/providers/bundled_tts_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BundledTTSProvider', () {
    const MethodChannel channel = MethodChannel(bundledTtsChannelName);
    final List<MethodCall> calls = <MethodCall>[];
    Object? voicesResponse;

    setUp(() {
      calls.clear();
      voicesResponse = <Map<dynamic, dynamic>>[
        <String, dynamic>{
          'id': 'amy|en_US',
          'displayName': 'Amy',
          'locale': 'en_US',
          'gender': 'female',
        },
      ];
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        switch (call.method) {
          case 'availableVoices':
            return voicesResponse;
          case 'speak':
          case 'cancel':
            return null;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('channelName matches the careblazers/tts contract', () {
      expect(BundledTTSProvider.channelName, 'careblazers/tts');
      expect(bundledTtsChannelName, 'careblazers/tts');
    });

    test('is a TTSProvider', () {
      expect(BundledTTSProvider(), isA<TTSProvider>());
    });

    test('speak forwards text/voiceId/speed in a single map argument',
        () async {
      final BundledTTSProvider tts = BundledTTSProvider();
      await tts.speak('hello', voiceId: 'amy|en_US', speed: 1.2);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'speak');
      final Map<dynamic, dynamic> args =
          calls.single.arguments as Map<dynamic, dynamic>;
      expect(args['text'], 'hello');
      expect(args['voiceId'], 'amy|en_US');
      expect(args['speed'], 1.2);
    });

    test('speak passes an empty voiceId straight through (no auto-pick)',
        () async {
      // Auto-pick is an OSTTSProvider behavior (Settings → "use Siri").
      // The bundled provider just forwards — the native side decides
      // what to do with an empty id (in Phase 9.3/9.4 that becomes
      // "use the only bundled voice, Amy").
      final BundledTTSProvider tts = BundledTTSProvider();
      await tts.speak('plain', voiceId: '', speed: 1.0);
      final Map<dynamic, dynamic> args =
          calls.single.arguments as Map<dynamic, dynamic>;
      expect(args['voiceId'], '');
    });

    test('cancel forwards a bare cancel call with no arguments', () async {
      final BundledTTSProvider tts = BundledTTSProvider();
      await tts.cancel();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'cancel');
      expect(calls.single.arguments, isNull);
    });

    test('availableVoices parses the channel response into TTSVoice records',
        () async {
      voicesResponse = <Map<dynamic, dynamic>>[
        <String, dynamic>{
          'id': 'amy|en_US',
          'displayName': 'Amy',
          'locale': 'en_US',
          'gender': 'female',
        },
        <String, dynamic>{
          'id': 'ryan|en_US',
          'displayName': 'Ryan',
          'locale': 'en_US',
          'gender': 'male',
        },
      ];
      final BundledTTSProvider tts = BundledTTSProvider();
      final List<TTSVoice> voices = await tts.availableVoices();
      expect(voices, hasLength(2));
      expect(voices.first.id, 'amy|en_US');
      expect(voices.first.displayName, 'Amy');
      expect(voices.first.locale, 'en_US');
      expect(voices.first.gender, 'female');
      expect(voices.last.id, 'ryan|en_US');
      expect(voices.last.gender, 'male');
    });

    test('availableVoices defaults gender to "unknown" when absent',
        () async {
      voicesResponse = <Map<dynamic, dynamic>>[
        <String, dynamic>{
          'id': 'mystery|en_US',
          'displayName': 'Mystery',
          'locale': 'en_US',
        },
      ];
      final BundledTTSProvider tts = BundledTTSProvider();
      final List<TTSVoice> voices = await tts.availableVoices();
      expect(voices.single.gender, 'unknown');
    });

    test(
      'availableVoices skips malformed entries (non-map, missing keys)',
      () async {
        voicesResponse = <dynamic>[
          <String, dynamic>{
            'id': 'amy|en_US',
            'displayName': 'Amy',
            'locale': 'en_US',
          },
          <String, dynamic>{'displayName': 'Missing id + locale'},
          'not a map',
        ];
        final BundledTTSProvider tts = BundledTTSProvider();
        final List<TTSVoice> voices = await tts.availableVoices();
        expect(voices, hasLength(1));
        expect(voices.first.id, 'amy|en_US');
      },
    );

    test('availableVoices returns empty list when channel yields null',
        () async {
      voicesResponse = null;
      final BundledTTSProvider tts = BundledTTSProvider();
      final List<TTSVoice> voices = await tts.availableVoices();
      expect(voices, isEmpty);
    });

    // ---- Phase 9.7 ONNX-load failure fallback -----------------------------

    group('createOrFallback', () {
      test(
        'returns OSTTSProvider and warns once when probe throws PlatformException',
        () async {
          const MethodChannel failingChannel =
              MethodChannel('test/bundled-tts-fail');
          TestDefaultBinaryMessengerBinding
              .instance.defaultBinaryMessenger
              .setMockMethodCallHandler(failingChannel,
                  (MethodCall call) async {
            // Simulate the native bridge reporting an ONNX Runtime
            // load failure on the probe round-trip.
            throw PlatformException(
              code: 'ONNX_LOAD_FAILED',
              message: 'CoreML EP symbol missing',
            );
          });
          addTearDown(() {
            TestDefaultBinaryMessengerBinding
                .instance.defaultBinaryMessenger
                .setMockMethodCallHandler(failingChannel, null);
          });

          final List<String> warnings = <String>[];
          final OSTTSProvider canary = OSTTSProvider();
          final TTSProvider resolved =
              await BundledTTSProvider.createOrFallback(
            channel: failingChannel,
            osFallbackFactory: () => canary,
            warn: warnings.add,
          );
          expect(resolved, isA<OSTTSProvider>());
          expect(identical(resolved, canary), isTrue,
              reason: 'factory must hand back the injected OS fallback');
          expect(warnings, hasLength(1),
              reason: 'fallback must emit exactly one WARN line');
          expect(warnings.single, contains('ONNX_LOAD_FAILED'));
          expect(warnings.single, contains('CoreML EP symbol missing'));
          expect(warnings.single, contains('OSTTSProvider'));
        },
      );

      test(
        'returns OSTTSProvider and warns once when bridge is unregistered',
        () async {
          // No mock handler installed → the channel surfaces a
          // MissingPluginException, which the factory must treat the
          // same as an ONNX_LOAD_FAILED PlatformException.
          const MethodChannel unregistered =
              MethodChannel('test/bundled-tts-missing');

          final List<String> warnings = <String>[];
          final TTSProvider resolved =
              await BundledTTSProvider.createOrFallback(
            channel: unregistered,
            osFallbackFactory: OSTTSProvider.new,
            warn: warnings.add,
          );
          expect(resolved, isA<OSTTSProvider>());
          expect(warnings, hasLength(1));
          expect(warnings.single, contains('bridge unavailable'));
        },
      );

      test(
        'returns BundledTTSProvider and does not warn when probe succeeds',
        () async {
          const MethodChannel okChannel =
              MethodChannel('test/bundled-tts-ok');
          final List<MethodCall> probeCalls = <MethodCall>[];
          TestDefaultBinaryMessengerBinding
              .instance.defaultBinaryMessenger
              .setMockMethodCallHandler(okChannel, (MethodCall call) async {
            probeCalls.add(call);
            return null;
          });
          addTearDown(() {
            TestDefaultBinaryMessengerBinding
                .instance.defaultBinaryMessenger
                .setMockMethodCallHandler(okChannel, null);
          });

          final List<String> warnings = <String>[];
          final TTSProvider resolved =
              await BundledTTSProvider.createOrFallback(
            channel: okChannel,
            warn: warnings.add,
          );
          expect(resolved, isA<BundledTTSProvider>());
          expect(warnings, isEmpty,
              reason: 'happy path must not emit the WARN line');
          expect(probeCalls.single.method, 'probe',
              reason: 'factory probes via the careblazers/tts probe verb');
        },
      );
    });

    test('accepts an injected MethodChannel (test seam)', () async {
      const MethodChannel custom = MethodChannel('test/bundled-tts-custom');
      final List<MethodCall> customCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(custom, (MethodCall call) async {
        customCalls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(custom, null);
      });

      final BundledTTSProvider tts = BundledTTSProvider(channel: custom);
      await tts.cancel();
      expect(customCalls, hasLength(1));
      expect(customCalls.single.method, 'cancel');
      // The default channel must not have been touched.
      expect(calls, isEmpty);
    });
  });
}

import 'package:careblazers/providers/analytics_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Recording spy used only to prove the riverpod override hook actually
/// routes through to the override impl — the v1 default is the silent
/// no-op (BUILD_SPEC.md §6.5), so we never wire this into production.
class _RecordingAnalyticsProvider implements AnalyticsProvider {
  _RecordingAnalyticsProvider();

  final List<MapEntry<String, Map<String, Object?>>> events =
      <MapEntry<String, Map<String, Object?>>>[];
  final List<String> screens = <String>[];
  final List<String> users = <String>[];

  @override
  void trackEvent(String name, Map<String, Object?> properties) {
    events.add(MapEntry<String, Map<String, Object?>>(name, properties));
  }

  @override
  void trackScreen(String routeName) {
    screens.add(routeName);
  }

  @override
  void setUser({required String userId}) {
    users.add(userId);
  }
}

void main() {
  // ---- NoopAnalyticsProvider ---------------------------------------------

  group('NoopAnalyticsProvider', () {
    test('trackEvent swallows the call without throwing', () {
      const NoopAnalyticsProvider noop = NoopAnalyticsProvider();
      // No assertion on side effects — there are none. The contract is
      // simply "no exception escapes" (BUILD_SPEC.md §6.5).
      expect(
        () => noop.trackEvent('decoder_run', <String, Object?>{
          'behavior': 'sundowning',
          'attempt': 1,
          'voice_played': true,
        }),
        returnsNormally,
      );
    });

    test('trackEvent tolerates empty + null-valued properties', () {
      const NoopAnalyticsProvider noop = NoopAnalyticsProvider();
      expect(() => noop.trackEvent('empty', <String, Object?>{}),
          returnsNormally);
      expect(
        () => noop.trackEvent('nulls', <String, Object?>{
          'a': null,
          'b': null,
        }),
        returnsNormally,
      );
    });

    test('trackScreen swallows the call without throwing', () {
      const NoopAnalyticsProvider noop = NoopAnalyticsProvider();
      expect(() => noop.trackScreen('/decoder/triage'), returnsNormally);
      expect(() => noop.trackScreen(''), returnsNormally);
    });

    test('setUser swallows the call without throwing', () {
      const NoopAnalyticsProvider noop = NoopAnalyticsProvider();
      expect(
        () => noop.setUser(userId: 'demo-user-sarah'),
        returnsNormally,
      );
    });

    test('still implements AnalyticsProvider', () {
      const NoopAnalyticsProvider noop = NoopAnalyticsProvider();
      expect(noop, isA<AnalyticsProvider>());
    });
  });

  // ---- Riverpod wiring ---------------------------------------------------

  group('analyticsProvider riverpod selection', () {
    test('default container resolves to a NoopAnalyticsProvider', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final AnalyticsProvider impl = container.read(analyticsProvider);
      expect(impl, isA<NoopAnalyticsProvider>());
    });

    test('override hook swaps in a custom impl end-to-end', () {
      final _RecordingAnalyticsProvider spy = _RecordingAnalyticsProvider();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          analyticsProvider.overrideWithValue(spy),
        ],
      );
      addTearDown(container.dispose);

      final AnalyticsProvider impl = container.read(analyticsProvider);
      expect(identical(impl, spy), isTrue);

      impl.trackEvent('decoder_run', <String, Object?>{'behavior': 'upset'});
      impl.trackScreen('/decoder/result');
      impl.setUser(userId: 'demo-user-sarah');

      expect(spy.events, hasLength(1));
      expect(spy.events.single.key, 'decoder_run');
      expect(spy.events.single.value['behavior'], 'upset');
      expect(spy.screens, <String>['/decoder/result']);
      expect(spy.users, <String>['demo-user-sarah']);
    });
  });
}

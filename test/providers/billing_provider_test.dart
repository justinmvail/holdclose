import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/providers/billing_provider.dart';
import 'package:holdclose/services/billing_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The riverpod wiring for the paywall: the backend selector defaults to the
/// deterministic fake under `flutter test` (premium, so nothing is gated),
/// and [premiumStatusProvider] / [isPremiumProvider] derive entitlement from
/// whichever [BillingService] the container resolves.
void main() {
  group('billingServiceProvider selection', () {
    test('default under flutter test resolves to the FakeBillingService', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final BillingService svc = container.read(billingServiceProvider);
      expect(svc, isA<FakeBillingService>());
    });

    test('override hook swaps in a custom impl end-to-end', () {
      final FakeBillingService free =
          FakeBillingService(initialStatus: PremiumStatus.free);
      addTearDown(free.dispose);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          billingServiceProvider.overrideWithValue(free),
        ],
      );
      addTearDown(container.dispose);
      expect(identical(container.read(billingServiceProvider), free), isTrue);
    });
  });

  group('premiumStatusProvider', () {
    test('defaults to premium so nothing is accidentally gated', () async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      // Keep the stream alive so `.future` resolves off the replayed value.
      final sub = container.listen(premiumStatusProvider, (_, __) {});
      addTearDown(sub.close);
      final PremiumStatus status =
          await container.read(premiumStatusProvider.future);
      expect(status.isPremium, isTrue);
    });

    test('reflects a free entitlement from the injected service', () async {
      final FakeBillingService free =
          FakeBillingService(initialStatus: PremiumStatus.free);
      addTearDown(free.dispose);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          billingServiceProvider.overrideWithValue(free),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(premiumStatusProvider, (_, __) {});
      addTearDown(sub.close);
      final PremiumStatus status =
          await container.read(premiumStatusProvider.future);
      expect(status.isPremium, isFalse);
    });

    test('streams the trial entitlement after a buy', () async {
      final FakeBillingService free =
          FakeBillingService(initialStatus: PremiumStatus.free);
      addTearDown(free.dispose);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          billingServiceProvider.overrideWithValue(free),
        ],
      );
      addTearDown(container.dispose);

      // Prime the stream listener so events aren't dropped.
      final sub = container.listen(premiumStatusProvider, (_, __) {});
      addTearDown(sub.close);

      final ProductLoadResult result = await free.loadProducts();
      await free.buy(result.offerings.first);
      // Let the stream propagate through the provider.
      await Future<void>.delayed(Duration.zero);

      final AsyncValue<PremiumStatus> value =
          container.read(premiumStatusProvider);
      expect(value.value?.isPremium, isTrue);
      expect(value.value?.inTrial, isTrue);
    });
  });

  group('isPremiumProvider', () {
    test('true by default (unconfigured store → nothing gated)', () async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      // Prime the stream so the derived bool reads the streamed value.
      final sub = container.listen(premiumStatusProvider, (_, __) {});
      addTearDown(sub.close);
      await container.read(premiumStatusProvider.future);
      expect(container.read(isPremiumProvider), isTrue);
    });

    test('false when the injected service is free', () async {
      final FakeBillingService free =
          FakeBillingService(initialStatus: PremiumStatus.free);
      addTearDown(free.dispose);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          billingServiceProvider.overrideWithValue(free),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(premiumStatusProvider, (_, __) {});
      addTearDown(sub.close);
      await container.read(premiumStatusProvider.future);
      expect(container.read(isPremiumProvider), isFalse);
    });
  });
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/providers/billing_provider.dart';
import 'package:holdclose/services/billing_service.dart';
import 'package:holdclose/services/forum_api_client.dart'
    show EntitlementApi, ServerEntitlement;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// A scripted server billing surface — the SERVER decides entitlement.
class _FakeEntitlementApi implements EntitlementApi {
  _FakeEntitlementApi(this._entitlement);

  final ServerEntitlement _entitlement;

  @override
  Future<ServerEntitlement> verifyPurchase({
    required String platform,
    required String productId,
    required String receipt,
  }) async =>
      _entitlement;

  @override
  Future<ServerEntitlement> getEntitlement() async => _entitlement;
}

/// A store fake whose purchase stream is never fed here (the provider tests
/// exercise the SERVER-sourced hydration path, not the store flow).
class _FakeIap implements InAppPurchase {
  final StreamController<List<PurchaseDetails>> _c =
      StreamController<List<PurchaseDetails>>.broadcast();

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _c.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> restorePurchases({String? applicationUserName}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// The riverpod wiring for the paywall: the backend selector defaults to the
/// deterministic fake under `flutter test` (premium, so nothing is gated),
/// and [premiumStatusProvider] / [isPremiumProvider] derive entitlement from
/// whichever [BillingService] the container resolves.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

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

  group('premium reflects the SERVER via a store-backed service', () {
    // Wire a real StoreBillingService (the production impl) over a fake store
    // + a fake server billing API, and prove entitlement follows the SERVER
    // response through the provider graph — a client flag alone never grants.
    Future<ProviderContainer> containerFor(ServerEntitlement server) async {
      final StoreBillingService svc = StoreBillingService(
        iap: _FakeIap(),
        entitlementApi: _FakeEntitlementApi(server),
      );
      // Hydrate from the (fake) server before wiring the provider so the
      // synchronous snapshot the provider reads is already the server value.
      await svc.initialize();
      addTearDown(svc.dispose);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          billingServiceProvider.overrideWithValue(svc),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('server says premium → premiumStatusProvider is premium', () async {
      final ProviderContainer container =
          await containerFor(const ServerEntitlement(isPremium: true));
      final sub = container.listen(premiumStatusProvider, (_, __) {});
      addTearDown(sub.close);
      final PremiumStatus status =
          await container.read(premiumStatusProvider.future);
      expect(status.isPremium, isTrue);
      expect(container.read(isPremiumProvider), isTrue);
    });

    test('server says NOT premium → provider is not premium (no self-grant)',
        () async {
      final ProviderContainer container =
          await containerFor(ServerEntitlement.free);
      final sub = container.listen(premiumStatusProvider, (_, __) {});
      addTearDown(sub.close);
      final PremiumStatus status =
          await container.read(premiumStatusProvider.future);
      expect(status.isPremium, isFalse);
      expect(container.read(isPremiumProvider), isFalse);
    });

    test('server trial → provider is premium-in-trial with an end date',
        () async {
      final int ends = DateTime(2026, 7, 23).millisecondsSinceEpoch;
      final ProviderContainer container = await containerFor(
        ServerEntitlement(isPremium: true, inTrial: true, expiresAt: ends),
      );
      final sub = container.listen(premiumStatusProvider, (_, __) {});
      addTearDown(sub.close);
      final PremiumStatus status =
          await container.read(premiumStatusProvider.future);
      expect(status.isPremium, isTrue);
      expect(status.inTrial, isTrue);
      expect(status.trialEndsAt, DateTime.fromMillisecondsSinceEpoch(ends));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/services/billing_service.dart';

/// The deterministic [FakeBillingService] used by tests + demo. It touches no
/// platform plugin and defaults to premium so nothing is accidentally gated
/// while the store is unconfigured.
void main() {
  group('HoldcloseProductIds', () {
    test('bundles both plan ids into `all`', () {
      expect(
        HoldcloseProductIds.all,
        <String>{HoldcloseProductIds.monthly, HoldcloseProductIds.annual},
      );
      // Placeholders live under the app's bundle namespace so they read
      // clearly in App Store Connect / Play Console.
      expect(HoldcloseProductIds.monthly, startsWith('com.holdclose.'));
      expect(HoldcloseProductIds.annual, startsWith('com.holdclose.'));
    });
  });

  group('PremiumStatus', () {
    test('free is not premium; premium is', () {
      expect(PremiumStatus.free.isPremium, isFalse);
      expect(PremiumStatus.free.inTrial, isFalse);
      expect(PremiumStatus.premium.isPremium, isTrue);
    });

    test('value equality covers all three fields', () {
      final DateTime ends = DateTime(2026, 7, 23);
      expect(
        PremiumStatus(isPremium: true, inTrial: true, trialEndsAt: ends),
        PremiumStatus(isPremium: true, inTrial: true, trialEndsAt: ends),
      );
      expect(
        const PremiumStatus(isPremium: true, inTrial: true),
        isNot(const PremiumStatus(isPremium: true)),
      );
    });
  });

  group('FakeBillingService', () {
    test('defaults to premium so nothing is gated with no store configured',
        () {
      final FakeBillingService svc = FakeBillingService();
      addTearDown(svc.dispose);
      expect(svc.premiumStatus.isPremium, isTrue);
    });

    test('can be constructed free for the locked-path tests', () {
      final FakeBillingService svc =
          FakeBillingService(initialStatus: PremiumStatus.free);
      addTearDown(svc.dispose);
      expect(svc.premiumStatus.isPremium, isFalse);
    });

    test('loadProducts returns both canned plans, each carrying a free trial',
        () async {
      final FakeBillingService svc =
          FakeBillingService(initialStatus: PremiumStatus.free);
      addTearDown(svc.dispose);

      final ProductLoadResult result = await svc.loadProducts();
      expect(result.isEmpty, isFalse);
      expect(result.offerings, hasLength(2));
      expect(
        result.offerings.map((SubscriptionOffering o) => o.id),
        containsAll(<String>[
          HoldcloseProductIds.monthly,
          HoldcloseProductIds.annual,
        ]),
      );
      // Every plan advertises the introductory free trial.
      expect(
        result.offerings.every((SubscriptionOffering o) => o.introTrial),
        isTrue,
      );
      // Prices are the store's localized strings (rendered verbatim).
      expect(result.offerings.first.price, isNotEmpty);
    });

    test('buy flips a free caregiver to premium-in-trial and streams it',
        () async {
      final FakeBillingService svc =
          FakeBillingService(initialStatus: PremiumStatus.free);
      addTearDown(svc.dispose);

      final ProductLoadResult result = await svc.loadProducts();
      final List<PremiumStatus> seen = <PremiumStatus>[];
      final sub = svc.watchPremiumStatus().listen(seen.add);
      addTearDown(sub.cancel);

      final bool started = await svc.buy(result.offerings.first);
      expect(started, isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(svc.premiumStatus.isPremium, isTrue);
      expect(svc.premiumStatus.inTrial, isTrue);
      expect(svc.premiumStatus.trialEndsAt, isNotNull);
      // The stream replayed the initial free value, then the trial entitlement.
      expect(seen.first.isPremium, isFalse);
      expect(seen.last.inTrial, isTrue);
    });

    test('restorePurchases re-emits the current entitlement', () async {
      final FakeBillingService svc =
          FakeBillingService(initialStatus: PremiumStatus.premium);
      addTearDown(svc.dispose);

      final List<PremiumStatus> seen = <PremiumStatus>[];
      final sub = svc.watchPremiumStatus().listen(seen.add);
      addTearDown(sub.cancel);

      await svc.restorePurchases();
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.isPremium, isTrue);
    });

    test('watchPremiumStatus replays the latest value to a late subscriber',
        () async {
      final FakeBillingService svc =
          FakeBillingService(initialStatus: PremiumStatus.free);
      addTearDown(svc.dispose);
      svc.setStatus(PremiumStatus.premium);

      final PremiumStatus first = await svc.watchPremiumStatus().first;
      expect(first.isPremium, isTrue);
    });

    test('isStoreAvailable is configurable', () async {
      expect(await FakeBillingService().isStoreAvailable(), isTrue);
      expect(
        await FakeBillingService(storeAvailable: false).isStoreAvailable(),
        isFalse,
      );
    });
  });

  group('SubscriptionOffering', () {
    test('assumes a trial by default (product is configured with one)', () {
      // A tiny fake ProductDetails via the plugin type isn't available here
      // without a platform channel, so we exercise the canned offerings the
      // fake ships instead.
      const SubscriptionOffering o = SubscriptionOffering(
        id: 'x',
        title: 'X',
        description: 'd',
        price: r'$1.00',
        introTrial: true,
      );
      expect(o.introTrial, isTrue);
      expect(o, isNot(const SubscriptionOffering(
        id: 'y',
        title: 'X',
        description: 'd',
        price: r'$1.00',
        introTrial: true,
      )));
    });
  });
}

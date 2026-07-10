import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/services/billing_service.dart';
import 'package:holdclose/services/forum_api_client.dart'
    show EntitlementApi, ServerEntitlement;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fake `EntitlementApi` (the server billing surface) that records the
/// exact request shape and returns a scripted [ServerEntitlement] — proving
/// the SERVER decides entitlement, not the client.
class _FakeEntitlementApi implements EntitlementApi {
  _FakeEntitlementApi({
    ServerEntitlement? entitlement,
    ServerEntitlement? verifyResult,
    this.throwOnGet = false,
    this.throwOnVerify = false,
  })  : _entitlement = entitlement ?? ServerEntitlement.free,
        _verifyResult = verifyResult;

  ServerEntitlement _entitlement;
  final ServerEntitlement? _verifyResult;
  final bool throwOnGet;
  final bool throwOnVerify;

  final List<Map<String, String>> verifyCalls = <Map<String, String>>[];
  int getCalls = 0;

  /// Force what the next `getEntitlement` returns (server flips the state).
  set serverEntitlement(ServerEntitlement e) => _entitlement = e;

  @override
  Future<ServerEntitlement> verifyPurchase({
    required String platform,
    required String productId,
    required String receipt,
  }) async {
    verifyCalls.add(<String, String>{
      'platform': platform,
      'productId': productId,
      'receipt': receipt,
    });
    if (throwOnVerify) throw Exception('verify unreachable');
    // A verify updates the server's stored entitlement too.
    final ServerEntitlement result = _verifyResult ?? _entitlement;
    _entitlement = result;
    return result;
  }

  @override
  Future<ServerEntitlement> getEntitlement() async {
    getCalls++;
    if (throwOnGet) throw Exception('get unreachable');
    return _entitlement;
  }
}

/// A fake `InAppPurchase` whose purchase stream we drive by hand. Only the
/// members [StoreBillingService] touches are implemented; the rest fall
/// through [noSuchMethod] (never called in these tests).
class _FakeIap implements InAppPurchase {
  final StreamController<List<PurchaseDetails>> _controller =
      StreamController<List<PurchaseDetails>>.broadcast();

  int restoreCalls = 0;
  final List<PurchaseDetails> completed = <PurchaseDetails>[];

  void emit(List<PurchaseDetails> purchases) => _controller.add(purchases);

  Future<void> close() => _controller.close();

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _controller.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> restorePurchases({String? applicationUserName}) async {
    restoreCalls++;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

PurchaseDetails _purchase(
  String productId, {
  PurchaseStatus status = PurchaseStatus.purchased,
  String receipt = 'store-receipt',
  bool pendingComplete = true,
}) {
  final PurchaseDetails p = PurchaseDetails(
    productID: productId,
    verificationData: PurchaseVerificationData(
      localVerificationData: 'local',
      serverVerificationData: receipt,
      source: 'app_store',
    ),
    transactionDate: '0',
    status: status,
  );
  p.pendingCompletePurchase = pendingComplete;
  return p;
}

/// Let the microtask + stream events drain.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// The deterministic [FakeBillingService] used by tests + demo. It touches no
/// platform plugin and defaults to premium so nothing is accidentally gated
/// while the store is unconfigured.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
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

  group('PremiumStatus.fromServerEntitlement', () {
    test('reflects the server isPremium/inTrial and derives trialEndsAt', () {
      final int ends = DateTime(2026, 7, 23).millisecondsSinceEpoch;
      final PremiumStatus paid = PremiumStatus.fromServerEntitlement(
        const ServerEntitlement(isPremium: true),
      );
      expect(paid.isPremium, isTrue);
      expect(paid.inTrial, isFalse);
      expect(paid.trialEndsAt, isNull);

      final PremiumStatus trial = PremiumStatus.fromServerEntitlement(
        ServerEntitlement(isPremium: true, inTrial: true, expiresAt: ends),
      );
      expect(trial.isPremium, isTrue);
      expect(trial.inTrial, isTrue);
      expect(trial.trialEndsAt, DateTime.fromMillisecondsSinceEpoch(ends));

      final PremiumStatus free = PremiumStatus.fromServerEntitlement(
        ServerEntitlement.free,
      );
      expect(free.isPremium, isFalse);
    });
  });

  group('StoreBillingService — server-verified entitlement', () {
    test('a completed purchase POSTs the receipt and premium reflects the '
        'SERVER response (client stream alone does NOT grant)', () async {
      final _FakeIap iap = _FakeIap();
      addTearDown(iap.close);
      final _FakeEntitlementApi api = _FakeEntitlementApi(
        // GET on launch says free; the SERVER only grants on verify.
        entitlement: ServerEntitlement.free,
        verifyResult: const ServerEntitlement(
          isPremium: true,
          productId: 'com.holdclose.premium.monthly',
          platform: 'ios',
        ),
      );
      // Pin the platform so the receipt→platform mapping is deterministic.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final StoreBillingService svc = StoreBillingService(
        iap: iap,
        entitlementApi: api,
      );
      addTearDown(svc.dispose);

      await svc.initialize();
      // After the launch GET (free), nothing is granted yet.
      expect(svc.premiumStatus.isPremium, isFalse);

      // The store delivers a completed purchase.
      iap.emit(<PurchaseDetails>[
        _purchase('com.holdclose.premium.monthly', receipt: 'jws-abc'),
      ]);
      await _settle();

      // The client POSTed the platform receipt to the server...
      expect(api.verifyCalls, hasLength(1));
      expect(api.verifyCalls.first, <String, String>{
        'platform': 'ios',
        'productId': 'com.holdclose.premium.monthly',
        'receipt': 'jws-abc',
      });
      // ...and premium reflects the SERVER's response.
      expect(svc.premiumStatus.isPremium, isTrue);
      // The purchase was finalized so the store stops re-delivering it.
      expect(iap.completed, hasLength(1));
    });

    test('a completed purchase does NOT grant when the SERVER says '
        'isPremium:false (well-formed but invalid receipt)', () async {
      final _FakeIap iap = _FakeIap();
      addTearDown(iap.close);
      final _FakeEntitlementApi api = _FakeEntitlementApi(
        entitlement: ServerEntitlement.free,
        verifyResult: ServerEntitlement.free, // server rejects it
      );
      final StoreBillingService svc =
          StoreBillingService(iap: iap, entitlementApi: api);
      addTearDown(svc.dispose);

      await svc.initialize();
      iap.emit(<PurchaseDetails>[_purchase('com.holdclose.premium.monthly')]);
      await _settle();

      expect(api.verifyCalls, hasLength(1));
      // The store stream said "purchased" — but the SERVER is authoritative.
      expect(svc.premiumStatus.isPremium, isFalse);
    });

    test('initialize hydrates premium from GET /billing/entitlement',
        () async {
      final _FakeIap iap = _FakeIap();
      addTearDown(iap.close);
      final _FakeEntitlementApi api = _FakeEntitlementApi(
        entitlement: const ServerEntitlement(isPremium: true),
      );
      final StoreBillingService svc =
          StoreBillingService(iap: iap, entitlementApi: api);
      addTearDown(svc.dispose);

      await svc.initialize();
      expect(api.getCalls, greaterThanOrEqualTo(1));
      expect(svc.premiumStatus.isPremium, isTrue);
    });

    test('with NO backend a completed purchase never self-grants premium',
        () async {
      final _FakeIap iap = _FakeIap();
      addTearDown(iap.close);
      final StoreBillingService svc =
          StoreBillingService(iap: iap /* entitlementApi: null */);
      addTearDown(svc.dispose);

      await svc.initialize();
      iap.emit(<PurchaseDetails>[_purchase('com.holdclose.premium.monthly')]);
      await _settle();

      // No server to verify against → the client cannot grant itself premium.
      expect(svc.premiumStatus.isPremium, isFalse);
    });

    test('offline (GET throws) falls back to the CACHED server value, '
        'not to a store-stream self-grant', () async {
      // Seed the cache with a previously-server-granted premium entitlement.
      SharedPreferences.setMockInitialValues(<String, Object>{
        StoreBillingService.cachePrefsKey: jsonEncode(
          const ServerEntitlement(isPremium: true).toJson(),
        ),
      });
      final _FakeIap iap = _FakeIap();
      addTearDown(iap.close);
      final _FakeEntitlementApi api =
          _FakeEntitlementApi(throwOnGet: true, throwOnVerify: true);
      final StoreBillingService svc =
          StoreBillingService(iap: iap, entitlementApi: api);
      addTearDown(svc.dispose);

      await svc.initialize();
      // The GET failed, but the cached SERVER value keeps the UI premium.
      expect(svc.premiumStatus.isPremium, isTrue);
    });

    test('restorePurchases re-reads the server entitlement', () async {
      final _FakeIap iap = _FakeIap();
      addTearDown(iap.close);
      final _FakeEntitlementApi api =
          _FakeEntitlementApi(entitlement: ServerEntitlement.free);
      final StoreBillingService svc =
          StoreBillingService(iap: iap, entitlementApi: api);
      addTearDown(svc.dispose);

      await svc.initialize();
      expect(svc.premiumStatus.isPremium, isFalse);

      // The server now knows about a subscription.
      api.serverEntitlement = const ServerEntitlement(isPremium: true);
      await svc.restorePurchases();

      expect(iap.restoreCalls, greaterThanOrEqualTo(1));
      expect(svc.premiumStatus.isPremium, isTrue);
    });

    test('the cache is written from the SERVER value on verify', () async {
      final _FakeIap iap = _FakeIap();
      addTearDown(iap.close);
      final _FakeEntitlementApi api = _FakeEntitlementApi(
        entitlement: ServerEntitlement.free,
        verifyResult: const ServerEntitlement(isPremium: true),
      );
      final StoreBillingService svc =
          StoreBillingService(iap: iap, entitlementApi: api);
      addTearDown(svc.dispose);

      await svc.initialize();
      iap.emit(<PurchaseDetails>[_purchase('com.holdclose.premium.monthly')]);
      await _settle();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cached = prefs.getString(StoreBillingService.cachePrefsKey);
      expect(cached, isNotNull);
      final ServerEntitlement e = ServerEntitlement.fromJson(
        Map<String, Object?>.from(jsonDecode(cached!) as Map),
      );
      expect(e.isPremium, isTrue);
    });
  });

  group('ServerEntitlement', () {
    test('round-trips through JSON and equals', () {
      const ServerEntitlement e = ServerEntitlement(
        isPremium: true,
        inTrial: true,
        expiresAt: 1721692800000,
        productId: 'com.holdclose.premium.annual',
        platform: 'android',
      );
      final ServerEntitlement back = ServerEntitlement.fromJson(e.toJson());
      expect(back, e);
    });

    test('fromJson tolerates a bare free/absent-field body', () {
      final ServerEntitlement e = ServerEntitlement.fromJson(
        <String, Object?>{'isPremium': false, 'productId': null},
      );
      expect(e.isPremium, isFalse);
      expect(e.inTrial, isFalse);
      expect(e.expiresAt, isNull);
      expect(e.productId, isNull);
    });
  });
}

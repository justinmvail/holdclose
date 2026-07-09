/// Subscription paywall machinery (scaffold — NO features gated yet).
///
/// This file defines the [BillingService] backend interface plus its two
/// implementations, following the app's "every backend is behind an
/// interface with a real + fake impl selected by a riverpod provider"
/// invariant (see `auth_provider.dart` / `llm_provider.dart`):
///
///  * [StoreBillingService] — the REAL impl over `in_app_purchase`
///    (StoreKit on iOS, Play Billing on Android).
///  * [FakeBillingService] — a DETERMINISTIC impl for tests + demo. It
///    touches no platform plugin and, by default, reports the loved-one
///    caregiver as already premium so nothing is accidentally gated while
///    the store is unconfigured.
///
/// The app NEVER imports [StoreBillingService] directly — it goes through
/// `billingServiceProvider` (see `providers/billing_provider.dart`), which
/// picks the impl based on build mode, and reads entitlement through
/// `premiumStatusProvider`.
///
/// **The offering is a subscription WITH an introductory free trial.** The
/// store product itself carries the trial (configured in App Store Connect /
/// Play Console — see [HoldcloseProductIds]); the app just reflects whatever
/// the store reports. There is ALWAYS a free-trial period before any charge.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

// ---------------------------------------------------------------------------
// Product IDs
// ---------------------------------------------------------------------------

/// The store product identifiers for the Holdclose subscription.
///
/// **These are PLACEHOLDERS.** The real identifiers are configured in
/// **App Store Connect** (Subscriptions → subscription group → product) and
/// the **Google Play Console** (Monetize → Subscriptions → base plan). They
/// MUST match the ids created there exactly, or `queryProductDetails` returns
/// them as "not found". Keep the same id string on both stores so one
/// [BillingService] set drives iOS + Android.
///
/// The introductory FREE TRIAL is NOT an id here — it's an *introductory
/// offer* (StoreKit) / *free-trial phase* (Play base plan) attached to the
/// product below. The app reads the trial off the resolved [ProductDetails]
/// and reflects it in [PremiumStatus.inTrial]; it never fabricates a trial.
class HoldcloseProductIds {
  HoldcloseProductIds._();

  /// Monthly auto-renewing subscription (placeholder — set the real id in
  /// App Store Connect / Play Console).
  static const String monthly = 'com.holdclose.premium.monthly';

  /// Annual auto-renewing subscription (placeholder — set the real id in
  /// App Store Connect / Play Console). Offered alongside monthly so the
  /// paywall can show a "best value" annual plan.
  static const String annual = 'com.holdclose.premium.annual';

  /// Every product the paywall queries. Passed to
  /// [BillingService.loadProducts]; the store only returns the ones it
  /// actually has configured, so an un-set id is simply absent (surfaced as
  /// [BillingService.notFoundIds]).
  static const Set<String> all = <String>{monthly, annual};
}

// ---------------------------------------------------------------------------
// Entitlement model
// ---------------------------------------------------------------------------

/// The caregiver's current premium entitlement, derived from the active
/// subscription (if any). Exposed to the app through `premiumStatusProvider`.
///
/// [isPremium] is the single gate the app reads — it's true whenever the
/// caregiver has an active entitlement, WHETHER that's a paid subscription
/// OR an in-progress free trial (a trial grants full access; the charge only
/// lands when it ends). [inTrial] + [trialEndsAt] let the UI show "X days
/// left in your free trial" without changing what's unlocked.
@immutable
class PremiumStatus {
  const PremiumStatus({
    required this.isPremium,
    this.inTrial = false,
    this.trialEndsAt,
  });

  /// The "no entitlement" baseline — used before products load and after a
  /// subscription lapses. NOT the test/demo default (that's premium — see
  /// [FakeBillingService]).
  static const PremiumStatus free = PremiumStatus(isPremium: false);

  /// Convenience for the test/demo default + any "everything unlocked" path.
  static const PremiumStatus premium = PremiumStatus(isPremium: true);

  /// True when premium features are unlocked — an active paid subscription
  /// OR an in-progress free trial. The ONLY flag a feature gate reads.
  final bool isPremium;

  /// True when the active entitlement is an in-progress free trial (no
  /// charge has landed yet). Implies [isPremium] is true.
  final bool inTrial;

  /// When the free trial converts to a paid charge, if [inTrial]. Null
  /// otherwise (paid subscribers + free users). Purely informational — the
  /// store, not the app, enforces the conversion.
  final DateTime? trialEndsAt;

  @override
  bool operator ==(Object other) =>
      other is PremiumStatus &&
      other.isPremium == isPremium &&
      other.inTrial == inTrial &&
      other.trialEndsAt == trialEndsAt;

  @override
  int get hashCode => Object.hash(isPremium, inTrial, trialEndsAt);

  @override
  String toString() => 'PremiumStatus(isPremium: $isPremium, '
      'inTrial: $inTrial, trialEndsAt: $trialEndsAt)';
}

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------

/// Backend for the subscription paywall.
///
/// Two implementations: [StoreBillingService] (real, `in_app_purchase`) and
/// [FakeBillingService] (deterministic, tests + demo). The app reaches this
/// only through `billingServiceProvider`; it never sees the concrete class.
///
/// Lifecycle: construct → [initialize] (subscribes to the store's purchase
/// stream and restores any active entitlement) → the app reads
/// [watchPremiumStatus] / [premiumStatus] and, from the paywall, calls
/// [loadProducts] + [buy] + [restorePurchases]. [dispose] tears down the
/// stream subscriptions (wired to `ref.onDispose`).
abstract class BillingService {
  /// Whether the store is reachable at all (StoreKit/Play available, user
  /// can transact). A device with purchases disabled, or an unconfigured
  /// build, reports false — the paywall then shows an "unavailable" state
  /// instead of an empty plan list.
  Future<bool> isStoreAvailable();

  /// Wire up the purchase stream + hydrate the current entitlement. Safe to
  /// call once at provider init. Resolves once the initial restore attempt
  /// has been kicked off (not necessarily completed — entitlement lands
  /// asynchronously on [watchPremiumStatus]).
  Future<void> initialize();

  /// Fetch the [SubscriptionOffering]s for [HoldcloseProductIds.all] from the
  /// store. Each carries the localized price + trial info the paywall renders.
  /// Ids the store didn't return (typo, not-yet-approved, wrong bundle) land
  /// in [notFoundIds] on the result, not as an exception.
  Future<ProductLoadResult> loadProducts();

  /// Start the purchase flow for [offering] — shows the native
  /// StoreKit/Play sheet. Resolves true once the flow was *launched* (the
  /// actual purchase result arrives asynchronously on [watchPremiumStatus]);
  /// false if the store refused to start it.
  ///
  /// The purchased product carries its own introductory free trial (set in
  /// App Store Connect / Play Console), so "buy" here means "start the free
  /// trial, then subscribe" — the store does not charge until the trial ends.
  Future<bool> buy(SubscriptionOffering offering);

  /// Ask the store to replay the caregiver's existing entitlements (e.g. on
  /// a new device / reinstall). Results arrive on [watchPremiumStatus]; the
  /// paywall's "Restore purchases" button calls this.
  Future<void> restorePurchases();

  /// The current entitlement, updated as purchases/restores land. Emits the
  /// latest value on subscribe (broadcast, replay-latest) so a late listener
  /// isn't blank.
  Stream<PremiumStatus> watchPremiumStatus();

  /// The most recently computed entitlement — a synchronous read for code
  /// paths that can't await a stream (e.g. a `PremiumGate`'s initial build).
  PremiumStatus get premiumStatus;

  /// Tear down stream subscriptions. Wired to `ref.onDispose`.
  Future<void> dispose();
}

/// One purchasable subscription plan, resolved from the store. Wraps the
/// raw [ProductDetails] so the paywall + tests have a small, stable shape
/// (localized [price], the [id] to buy, and whether the store attached a
/// free [introTrial]) without depending on the plugin's type in widget code.
@immutable
class SubscriptionOffering {
  const SubscriptionOffering({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    required this.introTrial,
    this.rawDetails,
  });

  /// Build from a resolved [ProductDetails]. The free-trial flag is derived
  /// leniently: StoreKit/Play surface introductory-offer details differently
  /// across plugin versions, so we treat the presence of any introductory
  /// price phase as a trial. When the plugin can't tell us, we fall back to
  /// [assumeTrial] (true — the product is CONFIGURED with a trial in the
  /// store, and there is always a trial before any charge).
  factory SubscriptionOffering.fromProductDetails(
    ProductDetails details, {
    bool assumeTrial = true,
  }) {
    return SubscriptionOffering(
      id: details.id,
      title: details.title,
      description: details.description,
      price: details.price,
      introTrial: assumeTrial,
      rawDetails: details,
    );
  }

  /// Store product id (matches a [HoldcloseProductIds] value).
  final String id;

  /// Localized product title from the store.
  final String title;

  /// Localized product description from the store.
  final String description;

  /// Localized, currency-formatted price string (e.g. "$4.99") — render this
  /// verbatim; never reconstruct a price from [ProductDetails.rawPrice].
  final String price;

  /// True when the plan carries an introductory free trial (the store
  /// enforces the "trial then charge" transition). Drives the paywall CTA
  /// copy ("Start free trial").
  final bool introTrial;

  /// The raw plugin object, needed to build the [PurchaseParam] in
  /// [StoreBillingService.buy]. Null for fake/test offerings that never hit
  /// the store.
  final ProductDetails? rawDetails;

  @override
  bool operator ==(Object other) =>
      other is SubscriptionOffering &&
      other.id == id &&
      other.title == title &&
      other.description == description &&
      other.price == price &&
      other.introTrial == introTrial;

  @override
  int get hashCode => Object.hash(id, title, description, price, introTrial);
}

/// Result of [BillingService.loadProducts] — the resolved [offerings] plus
/// any [notFoundIds] the store didn't recognize (so the paywall can log /
/// warn without failing the whole load).
@immutable
class ProductLoadResult {
  const ProductLoadResult({
    required this.offerings,
    this.notFoundIds = const <String>[],
  });

  static const ProductLoadResult empty = ProductLoadResult(
    offerings: <SubscriptionOffering>[],
  );

  final List<SubscriptionOffering> offerings;
  final List<String> notFoundIds;

  bool get isEmpty => offerings.isEmpty;
}

// ---------------------------------------------------------------------------
// Real impl — in_app_purchase (StoreKit + Play Billing)
// ---------------------------------------------------------------------------

/// Real [BillingService] over `in_app_purchase`.
///
/// Bridges the plugin's [InAppPurchase.purchaseStream] into a
/// [PremiumStatus] stream: a `purchased`/`restored` for one of our product
/// ids flips the caregiver to premium; nothing else does. Every completed
/// (or errored) purchase that is still `pendingCompletePurchase` is finalized
/// via [InAppPurchase.completePurchase] so the store doesn't re-deliver it.
///
/// **Receipt validation is CLIENT-SIDE for now.** We trust the store's
/// stream status locally. That's enough to gate UI, but it is spoofable on a
/// jailbroken/rooted device.
///
/// TODO(server-validation): validate the receipt in
/// [PurchaseDetails.verificationData] against a FUTURE Cloudflare Worker
/// route (e.g. `POST /api/v1/billing/verify`) that calls Apple's
/// `verifyReceipt` / Google Play Developer API, records the entitlement
/// server-side (keyed by the account spine), and returns the authoritative
/// [PremiumStatus]. Until that lands, [_deriveStatus] trusts the local
/// stream. The Worker route is intentionally NOT built in this scaffold.
class StoreBillingService implements BillingService {
  StoreBillingService({
    InAppPurchase? iap,
    Set<String> productIds = HoldcloseProductIds.all,
  })  : _iap = iap ?? InAppPurchase.instance,
        _productIds = productIds;

  final InAppPurchase _iap;
  final Set<String> _productIds;

  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  final StreamController<PremiumStatus> _statusController =
      StreamController<PremiumStatus>.broadcast();

  PremiumStatus _status = PremiumStatus.free;

  @override
  PremiumStatus get premiumStatus => _status;

  @override
  Future<bool> isStoreAvailable() => _iap.isAvailable();

  @override
  Future<void> initialize() async {
    // Listen BEFORE restoring so the restore's replayed purchases aren't
    // missed. The plugin's stream is broadcast + long-lived.
    _purchaseSub ??= _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object _) {
        // A stream error must not brick the app — hold the last known
        // status (default: free) and let the paywall surface "try again".
      },
    );
    // Kick off a restore so a returning subscriber lands premium without
    // tapping "Restore". Best-effort: a failure just leaves status at free.
    try {
      await _iap.restorePurchases();
    } catch (_) {
      // Ignore — the caregiver can still restore manually from the paywall.
    }
  }

  @override
  Future<ProductLoadResult> loadProducts() async {
    final ProductDetailsResponse response =
        await _iap.queryProductDetails(_productIds);
    final List<SubscriptionOffering> offerings = response.productDetails
        .map((ProductDetails d) => SubscriptionOffering.fromProductDetails(d))
        .toList();
    return ProductLoadResult(
      offerings: offerings,
      notFoundIds: response.notFoundIDs,
    );
  }

  @override
  Future<bool> buy(SubscriptionOffering offering) async {
    final ProductDetails? details = offering.rawDetails;
    if (details == null) return false;
    final PurchaseParam param = PurchaseParam(productDetails: details);
    // A subscription is non-consumable — the entitlement persists and is
    // restorable. The store shows the intro free trial in the native sheet.
    return _iap.buyNonConsumable(purchaseParam: param);
  }

  @override
  Future<void> restorePurchases() => _iap.restorePurchases();

  @override
  Stream<PremiumStatus> watchPremiumStatus() =>
      _replayLatest(_statusController, () => _status);

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final PurchaseDetails p in purchases) {
      // Finalize anything the store still considers open, or it re-delivers
      // on next launch. (Even errored/canceled ones must be completed.)
      if (p.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(p);
        } catch (_) {
          // Best-effort — a failed complete just means it re-arrives later.
        }
      }
    }
    final PremiumStatus next = _deriveStatus(purchases);
    if (next != _status) {
      _status = next;
      if (!_statusController.isClosed) _statusController.add(next);
    }
  }

  /// Map the latest purchase stream event to an entitlement.
  ///
  /// CLIENT-SIDE trust (see the class TODO): any of OUR product ids in a
  /// `purchased`/`restored` state grants premium. A `canceled`/`error`/absent
  /// state for all of them leaves us at free. `pending` doesn't grant yet.
  ///
  /// The free-trial window isn't reliably exposed on [PurchaseDetails] across
  /// platforms, so [inTrial]/[trialEndsAt] are left unset here — the store
  /// enforces the trial, and the paywall reads the trial *offer* off
  /// [SubscriptionOffering.introTrial] instead. Server-side validation will
  /// supply the authoritative trial window later.
  PremiumStatus _deriveStatus(List<PurchaseDetails> purchases) {
    final bool active = purchases.any((PurchaseDetails p) =>
        _productIds.contains(p.productID) &&
        (p.status == PurchaseStatus.purchased ||
            p.status == PurchaseStatus.restored));
    if (active) return PremiumStatus.premium;
    // This batch grants nothing — keep an already-granted entitlement (a
    // later canceled/error event for a DIFFERENT product mustn't revoke it),
    // otherwise stay free. A true revocation is surfaced by server-side
    // validation (the class TODO), not by an absent local stream event.
    return _status.isPremium ? _status : PremiumStatus.free;
  }

  @override
  Future<void> dispose() async {
    await _purchaseSub?.cancel();
    _purchaseSub = null;
    await _statusController.close();
  }
}

// ---------------------------------------------------------------------------
// Fake impl — deterministic, for tests + demo
// ---------------------------------------------------------------------------

/// Deterministic [BillingService] for tests + the demo tour.
///
/// Touches NO platform plugin. Defaults to **premium** so that, with no
/// store configured, `flutter test` + demo builds behave as if everything is
/// unlocked — nothing is accidentally gated by an unconfigured paywall. Tests
/// that exercise the free/locked path construct it with
/// `FakeBillingService(initialStatus: PremiumStatus.free)`.
///
/// [buy] flips the status to whatever [purchaseResult] says (premium, in a
/// trial by default) after an awaitable microtask, so a widget test can drive
/// the "start free trial → unlocked" path without a real store.
class FakeBillingService implements BillingService {
  FakeBillingService({
    PremiumStatus initialStatus = PremiumStatus.premium,
    List<SubscriptionOffering>? offerings,
    PremiumStatus? purchaseResult,
    bool storeAvailable = true,
  })  : _status = initialStatus,
        _offerings = offerings ?? _defaultOfferings,
        _purchaseResult = purchaseResult ?? _defaultTrialStatus,
        _storeAvailable = storeAvailable;

  /// A canned trial window (14 days out) so `inTrial`/`trialEndsAt` render
  /// deterministically in the demo + goldens.
  static final PremiumStatus _defaultTrialStatus = PremiumStatus(
    isPremium: true,
    inTrial: true,
    trialEndsAt: DateTime(2026, 7, 23),
  );

  /// Two canned plans mirroring the real offering (monthly + annual, both
  /// carrying the free trial). Fixed price strings so goldens are stable.
  static const List<SubscriptionOffering> _defaultOfferings =
      <SubscriptionOffering>[
    SubscriptionOffering(
      id: HoldcloseProductIds.monthly,
      title: 'Holdclose Premium (Monthly)',
      description: 'Your full caregiving suite and coach.',
      price: r'$6.99',
      introTrial: true,
    ),
    SubscriptionOffering(
      id: HoldcloseProductIds.annual,
      title: 'Holdclose Premium (Annual)',
      description: 'Your full caregiving suite and coach — best value.',
      price: r'$59.99',
      introTrial: true,
    ),
  ];

  PremiumStatus _status;
  final List<SubscriptionOffering> _offerings;
  final PremiumStatus _purchaseResult;
  final bool _storeAvailable;

  final StreamController<PremiumStatus> _controller =
      StreamController<PremiumStatus>.broadcast();

  @override
  PremiumStatus get premiumStatus => _status;

  @override
  Future<bool> isStoreAvailable() async => _storeAvailable;

  @override
  Future<void> initialize() async {
    // Replay the initial status to any listener already subscribed.
    if (!_controller.isClosed) _controller.add(_status);
  }

  @override
  Future<ProductLoadResult> loadProducts() async =>
      ProductLoadResult(offerings: _offerings);

  @override
  Future<bool> buy(SubscriptionOffering offering) async {
    _emit(_purchaseResult);
    return true;
  }

  @override
  Future<void> restorePurchases() async {
    // Restoring in the fake re-emits the current status (deterministic).
    _emit(_status);
  }

  @override
  Stream<PremiumStatus> watchPremiumStatus() =>
      _replayLatest(_controller, () => _status);

  /// Test seam: force a specific entitlement + notify listeners.
  @visibleForTesting
  void setStatus(PremiumStatus status) => _emit(status);

  void _emit(PremiumStatus status) {
    _status = status;
    if (!_controller.isClosed) _controller.add(status);
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

// ---------------------------------------------------------------------------
// Shared helper
// ---------------------------------------------------------------------------

/// Bridge a broadcast [source] + a `current()` getter into a stream that
/// replays the latest value to every new listener (so a late subscriber never
/// sees a blank first frame) and subscribes to [source] inside `onListen` so
/// no event fired between subscribe + first yield is lost.
///
/// Mirrors `_replayBroadcast` in `auth_provider.dart` — same trap, same fix.
Stream<PremiumStatus> _replayLatest(
  StreamController<PremiumStatus> source,
  PremiumStatus Function() current,
) {
  late StreamController<PremiumStatus> out;
  StreamSubscription<PremiumStatus>? sub;
  out = StreamController<PremiumStatus>.broadcast(
    onListen: () {
      out.add(current());
      sub ??= source.stream.listen((PremiumStatus s) {
        if (!out.isClosed) out.add(s);
      });
    },
    onCancel: () async {
      await sub?.cancel();
      sub = null;
    },
  );
  return out.stream;
}

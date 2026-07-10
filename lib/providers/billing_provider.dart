import 'dart:io' show Platform;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/billing_service.dart';
import '../services/forum_api_client.dart'
    show EntitlementApi, forumApiClientProvider, forumBackendConfigured;

part 'billing_provider.g.dart';

/// Riverpod wiring for the subscription paywall (scaffold — NO features
/// gated yet). Follows the `authProvider` / `llmProvider` pattern: an
/// abstract [BillingService] behind a generated provider that picks the
/// impl by build mode, plus a derived [premiumStatusProvider] the app reads.
///
/// Defaults are chosen so the WHOLE app builds + every test passes with NO
/// store configured: under `flutter test` / demo mode the selector returns a
/// [FakeBillingService] that reports **premium**, so nothing is ever
/// accidentally gated by an unconfigured paywall.

/// Build-time flag (`--dart-define=DEMO_MODE`). A demo build uses the fake
/// billing service (premium) so the demo tour never hits a store sheet.
const bool _demoMode = bool.fromEnvironment('DEMO_MODE', defaultValue: false);

/// True only under `flutter test` (the harness exports `FLUTTER_TEST`). Any
/// lookup failure falls back to false so a real device never silently runs
/// the fake. Mirrors `_isUnderFlutterTest` in `llm_provider.dart`.
bool get _isUnderFlutterTest {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}

/// Whether to use the deterministic [FakeBillingService]. True under
/// `flutter test`, in demo mode, or when explicitly forced with
/// `--dart-define=USE_FAKE_BILLING=true`. An explicit define always wins.
///
/// A build that BAKES IN a real backend URL
/// (`--dart-define=FORUM_API_URL=...`) always uses the real
/// [StoreBillingService] (server-verified entitlement) — otherwise an
/// alpha/prod build would silently self-grant premium via the fake. The
/// explicit `USE_FAKE_BILLING` define still wins for the rare "real backend
/// but force-fake billing" bench case.
bool get _useFakeBilling {
  if (const bool.hasEnvironment('USE_FAKE_BILLING')) {
    return const bool.fromEnvironment('USE_FAKE_BILLING');
  }
  if (forumBackendConfigured) return false;
  return _demoMode || _isUnderFlutterTest;
}

/// Riverpod-wired backend selection. Widgets/services read
/// `ref.watch(billingServiceProvider)` and get whichever impl the build mode
/// picked — they never see the concrete class.
///
/// The function is named `billingBackend` (not `billing`) so the class
/// `riverpod_generator` emits is [BillingBackendProvider], avoiding a clash
/// with the abstract [BillingService] interface. Consumers read through the
/// [billingServiceProvider] alias below.
///
/// `initialize()` is fired on construction (fire-and-forget — entitlement
/// lands asynchronously on the status stream) and `dispose()` is wired to
/// `ref.onDispose` so the plugin's purchase-stream subscription is released.
@Riverpod(keepAlive: true)
BillingService billingBackend(Ref ref) {
  final BillingService service;
  if (_useFakeBilling) {
    service = FakeBillingService();
  } else {
    // Real store impl. When a backend is configured, hand it the
    // `EntitlementApi` (the forum client) so it VERIFIES purchases + hydrates
    // premium from the SERVER — the client never self-grants. With no backend
    // configured the api is null and the store impl reflects only its cached
    // server value / free (it still can't self-grant).
    final EntitlementApi? api =
        forumBackendConfigured ? ref.watch(forumApiClientProvider) : null;
    service = StoreBillingService(entitlementApi: api);
  }
  // Kick the store/purchase-stream wiring; a late entitlement restore
  // arrives on watchPremiumStatus(). Errors are swallowed inside initialize().
  service.initialize();
  ref.onDispose(service.dispose);
  return service;
}

/// Natural-language alias for the generated provider. Consumers should always
/// reach for this name — `billingBackendProvider` exists only because of the
/// riverpod_generator class-naming collision documented on [billingBackend].
final BillingBackendProvider billingServiceProvider = billingBackendProvider;

/// The caregiver's current premium entitlement, streamed from the active
/// [BillingService]. Exposes `{isPremium, inTrial, trialEndsAt?}` via
/// [PremiumStatus]. Reads the service's synchronous [BillingService
/// .premiumStatus] as the initial value so a `PremiumGate` never flickers to
/// "locked" for a frame before the stream's first event lands.
///
/// When a backend is configured this is sourced from the SERVER-verified
/// entitlement (`GET /billing/entitlement`, cached for offline) — the client
/// never self-grants. **Default is premium** under `flutter test` / demo /
/// no-backend builds (the fake reports premium), so nothing is accidentally
/// gated while the store is unconfigured.
@Riverpod(keepAlive: true)
Stream<PremiumStatus> premiumStatus(Ref ref) {
  final BillingService service = ref.watch(billingServiceProvider);
  return service.watchPremiumStatus();
}

/// Synchronous convenience: the current [PremiumStatus.isPremium], defaulting
/// to the service's last-known value while the stream is still resolving.
/// Handy for imperative checks (`if (ref.read(isPremiumProvider)) ...`) where
/// awaiting the async stream isn't practical.
@Riverpod(keepAlive: true)
bool isPremium(Ref ref) {
  // Prefer the freshest streamed value; fall back to the service's
  // synchronous snapshot before the first stream event arrives.
  final AsyncValue<PremiumStatus> streamed = ref.watch(premiumStatusProvider);
  return streamed.maybeWhen(
    data: (PremiumStatus s) => s.isPremium,
    orElse: () => ref.watch(billingServiceProvider).premiumStatus.isPremium,
  );
}

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'analytics_provider.g.dart';

/// Backend for product analytics (BUILD_SPEC.md §6.5).
///
/// v1 ships ONLY [NoopAnalyticsProvider] — there's no Mixpanel /
/// Amplitude / RevenueCat wiring yet (BUILD_SPEC.md §13.2 — "No
/// analytics in v1"). The abstract interface lives now so screen + route
/// code can call `analytics.trackScreen(...)` from day one and a real
/// impl can drop in behind the riverpod selector later without touching
/// the call sites.
abstract class AnalyticsProvider {
  /// Record a discrete event. [name] is a short identifier (e.g.
  /// `journal_entry_saved`); [properties] carry whatever fields the
  /// future real impl will want to slice on.
  void trackEvent(String name, Map<String, Object?> properties);

  /// Record a screen view by route name (e.g. `/journal/new`). Wired
  /// from the go_router observer.
  void trackScreen(String routeName);

  /// Associate subsequent events with [userId]. Called on sign-in.
  void setUser({required String userId});
}

/// Discards every call (BUILD_SPEC.md §6.5).
///
/// Default impl for v1. All methods are no-ops; nothing leaves the
/// device. Returning `void` (rather than `Future<void>`) matches the
/// interface so call sites don't await — analytics calls should never
/// block UI even when a real impl lands.
class NoopAnalyticsProvider implements AnalyticsProvider {
  const NoopAnalyticsProvider();

  @override
  void trackEvent(String name, Map<String, Object?> properties) {}

  @override
  void trackScreen(String routeName) {}

  @override
  void setUser({required String userId}) {}
}

/// Riverpod-wired backend selection (BUILD_SPEC.md §6.5).
///
/// Always returns [NoopAnalyticsProvider] in v1. Real impls (Mixpanel,
/// Amplitude, RevenueCat) drop in here when the privacy/compliance work
/// in §13.2 lands.
///
/// The function is named `analyticsBackend` (not `analytics`) so the
/// class `riverpod_generator` emits is [AnalyticsBackendProvider],
/// avoiding a clash with this file's own abstract [AnalyticsProvider]
/// interface. Consumers read through the [analyticsProvider] alias
/// below.
@Riverpod(keepAlive: true)
AnalyticsProvider analyticsBackend(Ref ref) => const NoopAnalyticsProvider();

/// Natural-language alias for the generated provider. Consumers should
/// always reach for this name — `analyticsBackendProvider` exists only
/// because of the riverpod_generator class-naming collision documented
/// on [analyticsBackend].
final AnalyticsBackendProvider analyticsProvider = analyticsBackendProvider;

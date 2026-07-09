import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/billing_provider.dart';
import '../routing/router.dart' show HoldcloseRoutes;

/// Feature-gating helpers for the subscription paywall (scaffold).
///
/// **IMPORTANT — NO current feature is gated yet.** Paywalling specific
/// features is a FUTURE step, and there is always a free-trial period before
/// any charge. These helpers exist so that, when the pricing decision lands,
/// a feature can be gated by wrapping it in a [PremiumGate] (or checking
/// [requirePremium]) WITHOUT re-plumbing entitlement — but nothing calls them
/// in production today.

/// Read the caregiver's current premium entitlement imperatively.
///
/// Returns true when premium features are unlocked — an active paid
/// subscription OR an in-progress free trial. In `flutter test` / demo builds
/// (no store configured) this is true by default, so gating logic is testable
/// without a store and nothing is accidentally locked.
///
/// Example (DO NOT wire to a real feature yet):
/// ```dart
/// // TODO(pricing): when the pricing decision lands, gate the chosen
/// // premium-only action like this — until then it stays ungated.
/// if (!requirePremium(ref)) {
///   context.pushNamed(HoldcloseRoutes.paywall);
///   return;
/// }
/// // ...run the premium-only action...
/// ```
bool requirePremium(WidgetRef ref) => ref.watch(isPremiumProvider);

/// Gate [child] behind an active premium entitlement.
///
/// When [isPremiumProvider] is true (which INCLUDES an in-progress free
/// trial, and is the default in test/demo), renders [child] unchanged. When
/// false, renders [locked] if provided, otherwise a compact upsell that routes
/// to the [PaywallScreen]. While the entitlement stream is still resolving it
/// falls back to the service's synchronous snapshot (via [isPremiumProvider]),
/// so there's no "locked" flicker for a returning subscriber.
///
/// **Documented example only — NOT wrapped around any current feature.**
/// When the pricing decision lands, a premium-only screen/section can be
/// gated like:
/// ```dart
/// // TODO(pricing): wrap the chosen premium-only surface once pricing is set.
/// PremiumGate(child: SomePremiumOnlySection())
/// ```
/// Until then this widget is unused in the app and only exercised by tests.
class PremiumGate extends ConsumerWidget {
  const PremiumGate({
    super.key,
    required this.child,
    this.locked,
  });

  /// The premium-only content, shown only when entitled.
  final Widget child;

  /// Optional replacement shown when NOT entitled. Defaults to a compact
  /// upsell card that opens the paywall.
  final Widget? locked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool premium = ref.watch(isPremiumProvider);
    if (premium) return child;
    return locked ?? const _DefaultLocked();
  }
}

/// The default "locked" placeholder — a single tappable row that routes to the
/// paywall. Deliberately minimal; a real gated feature would supply its own
/// [PremiumGate.locked] with feature-specific copy.
class _DefaultLocked extends StatelessWidget {
  const _DefaultLocked();

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Unlock with Holdclose Premium',
      child: InkWell(
        onTap: () => context.pushNamed(HoldcloseRoutes.paywall),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Unlock this with Holdclose Premium.',
            style: tt.bodyMedium,
          ),
        ),
      ),
    );
  }
}

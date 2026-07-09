import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/billing_provider.dart';
import '../../services/billing_service.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// The subscription paywall (`/premium`).
///
/// Shows the value prop, the plan(s) resolved from the store, a single
/// "Start free trial" CTA, a "Restore purchases" action, and the trusted,
/// code-side disclaimer line used elsewhere. NO feature is gated yet — this
/// screen is reachable machinery only (there's no route into it from a gated
/// feature). Every plan carries an introductory FREE TRIAL configured in the
/// store, so the CTA starts the trial; the store doesn't charge until it ends.
///
/// Reads plans + entitlement through [billingServiceProvider] /
/// [premiumStatusProvider]; in `flutter test` + demo that's the deterministic
/// [FakeBillingService], so the screen renders (and its golden captures)
/// without a store configured.
class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  static const Key startTrialButtonKey = Key('paywall-start-trial');
  static const Key restoreButtonKey = Key('paywall-restore');
  static const Key planListKey = Key('paywall-plans');
  static const Key disclaimerKey = Key('paywall-disclaimer');

  /// Trusted, code-side disclaimer — never sourced from any model / store
  /// string. Short, brand-voiced, no exclamation marks. States the two facts
  /// the caregiver needs before subscribing: it's a free trial first, and the
  /// store (not the app) manages billing.
  static const String disclaimerText =
      'Free trial first — cancel anytime before it ends and you will not be '
      'charged. Billing is managed by the App Store or Google Play.';

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  late Future<ProductLoadResult> _productsFuture;
  int _selectedIndex = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _productsFuture = ref.read(billingServiceProvider).loadProducts();
  }

  Future<void> _startTrial(List<SubscriptionOffering> offerings) async {
    if (_busy || offerings.isEmpty) return;
    setState(() => _busy = true);
    final SubscriptionOffering plan =
        offerings[_selectedIndex.clamp(0, offerings.length - 1)];
    bool started = false;
    try {
      started = await ref.read(billingServiceProvider).buy(plan);
    } catch (_) {
      started = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!started) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't start the checkout. Try again."),
      ));
    }
    // On success the native store sheet takes over; the entitlement lands on
    // premiumStatusProvider and any gated surface reacts. No manual nav here.
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(billingServiceProvider).restorePurchases();
    } catch (_) {
      // Swallow — surface a neutral result below.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Checked for previous purchases.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextTheme tt = theme.textTheme;
    // If the caregiver is already premium (the default in test/demo), show it
    // — the paywall is still reachable machinery, it just reflects the state.
    final bool alreadyPremium = ref.watch(isPremiumProvider);

    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Premium'),
                ],
                title: 'Holdclose Premium',
                leadingIcon: Icons.workspace_premium_outlined,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: <Widget>[
                  // Value prop.
                  Text(
                    'Everything, for the person you love',
                    style: tt.titleLarge?.copyWith(
                      color: context.hc.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Holdclose Premium keeps your full caregiving suite and '
                    'your coach — grounded in your loved one’s real care '
                    'details — working together in one place.',
                    style: tt.bodyMedium?.copyWith(color: context.hc.text),
                  ),
                  const SizedBox(height: 8),
                  const _ValueRow(text: 'A coach that knows your person'),
                  const _ValueRow(
                      text: 'Medications, appointments, and dose windows'),
                  const _ValueRow(
                      text: 'A shared Care Circle and shareable summaries'),
                  const SizedBox(height: 20),

                  if (alreadyPremium) ...<Widget>[
                    Container(
                      key: const Key('paywall-already-premium'),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: context.hc.surfaceWarm,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'You have Holdclose Premium. Thank you for being here.',
                        style: tt.bodyMedium?.copyWith(color: context.hc.text),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Plans + CTA, resolved from the store (fake in test/demo).
                  FutureBuilder<ProductLoadResult>(
                    future: _productsFuture,
                    builder: (BuildContext context,
                        AsyncSnapshot<ProductLoadResult> snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final ProductLoadResult result =
                          snap.data ?? ProductLoadResult.empty;
                      if (result.isEmpty) {
                        return Text(
                          'Plans aren’t available right now. Please try '
                          'again in a moment.',
                          style:
                              tt.bodyMedium?.copyWith(color: context.hc.text),
                        );
                      }
                      return _PlanSection(
                        offerings: result.offerings,
                        selectedIndex: _selectedIndex,
                        onSelect: (int i) =>
                            setState(() => _selectedIndex = i),
                        busy: _busy,
                        onStartTrial: () => _startTrial(result.offerings),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    key: PaywallScreen.restoreButtonKey,
                    onPressed: _busy ? null : _restore,
                    style: TextButton.styleFrom(
                      foregroundColor: context.hc.link,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    child: const Text('Restore purchases'),
                  ),
                  const SizedBox(height: 8),
                  // Trusted, code-side disclaimer — never from model/store output.
                  Text(
                    PaywallScreen.disclaimerText,
                    key: PaywallScreen.disclaimerKey,
                    textAlign: TextAlign.center,
                    style: tt.bodySmall?.copyWith(color: context.hc.primarySoft),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One bulleted value-prop line (decorative check — not a CTA, so the icon is
/// allowed per brand rules).
class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.check_circle_outline, size: 20, color: context.hc.cta),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: tt.bodyMedium?.copyWith(color: context.hc.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// The selectable plan cards + the single "Start free trial" CTA.
class _PlanSection extends StatelessWidget {
  const _PlanSection({
    required this.offerings,
    required this.selectedIndex,
    required this.onSelect,
    required this.busy,
    required this.onStartTrial,
  });

  final List<SubscriptionOffering> offerings;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool busy;
  final VoidCallback onStartTrial;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      key: PaywallScreen.planListKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < offerings.length; i++) ...<Widget>[
          _PlanCard(
            offering: offerings[i],
            selected: i == selectedIndex,
            onTap: () => onSelect(i),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 4),
        ElevatedButton(
          key: PaywallScreen.startTrialButtonKey,
          onPressed: busy ? null : onStartTrial,
          style: ElevatedButton.styleFrom(
            backgroundColor: context.hc.ctaFilled,
            foregroundColor: theme.colorScheme.onSecondary,
            minimumSize: const Size.fromHeight(52),
          ),
          // No emoji on the CTA (brand rule). Plain, clear label.
          child: Text(busy ? 'Starting…' : 'Start free trial'),
        ),
      ],
    );
  }
}

/// A single tappable plan card — title, price, and the free-trial note.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.offering,
    required this.selected,
    required this.onTap,
  });

  final SubscriptionOffering offering;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final Color border = selected ? context.hc.cta : context.hc.primarySoft;
    return Semantics(
      button: true,
      selected: selected,
      label: '${offering.title}, ${offering.price}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? context.hc.surfaceWarm : context.hc.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected ? context.hc.cta : context.hc.primarySoft,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      offering.title,
                      style: tt.titleMedium?.copyWith(
                        color: context.hc.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      offering.description,
                      style: tt.bodySmall?.copyWith(color: context.hc.text),
                    ),
                    if (offering.introTrial) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        'Includes a free trial',
                        style: tt.bodySmall?.copyWith(
                          color: context.hc.success,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                offering.price,
                style: tt.titleMedium?.copyWith(
                  color: context.hc.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/providers/billing_provider.dart';
import 'package:holdclose/screens/settings/paywall_screen.dart';
import 'package:holdclose/services/billing_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The subscription paywall. Uses the deterministic [FakeBillingService] so
/// it renders plans + drives the trial/restore flows without a real store.
Future<FakeBillingService> _pump(
  WidgetTester tester, {
  PremiumStatus initial = PremiumStatus.free,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final FakeBillingService billing =
      FakeBillingService(initialStatus: initial);
  addTearDown(billing.dispose);

  final GoRouter router = GoRouter(
    initialLocation: '/premium',
    routes: <RouteBase>[
      GoRoute(
        path: '/premium',
        builder: (BuildContext context, GoRouterState state) =>
            const PaywallScreen(),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        billingServiceProvider.overrideWithValue(billing),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return billing;
}

void main() {
  testWidgets('renders the value prop, both plans, and the trusted disclaimer',
      (WidgetTester tester) async {
    await _pump(tester);

    expect(find.text('Holdclose Premium'), findsOneWidget);
    expect(find.byKey(PaywallScreen.planListKey), findsOneWidget);
    expect(
        find.text('Holdclose Premium (Monthly)'), findsOneWidget);
    expect(find.text('Holdclose Premium (Annual)'), findsOneWidget);
    // The single, emoji-free "Start free trial" CTA.
    expect(find.byKey(PaywallScreen.startTrialButtonKey), findsOneWidget);
    expect(find.text('Start free trial'), findsOneWidget);
    // Restore + disclaimer.
    expect(find.byKey(PaywallScreen.restoreButtonKey), findsOneWidget);
    expect(find.byKey(PaywallScreen.disclaimerKey), findsOneWidget);
  });

  testWidgets('CTA carries no emoji or vendor name', (WidgetTester tester) async {
    await _pump(tester);
    final Text cta = tester.widget<Text>(find.descendant(
      of: find.byKey(PaywallScreen.startTrialButtonKey),
      matching: find.byType(Text),
    ));
    final String label = cta.data ?? '';
    expect(label, 'Start free trial');
    // No LLM vendor/model names anywhere in the paywall copy.
    for (final String banned in <String>[
      'ChatGPT',
      'Claude',
      'GPT',
      'OpenAI',
      'Anthropic',
    ]) {
      expect(find.textContaining(banned), findsNothing);
    }
  });

  testWidgets('Start free trial launches the store buy on the selected plan',
      (WidgetTester tester) async {
    final FakeBillingService billing = await _pump(tester);
    expect(billing.premiumStatus.isPremium, isFalse);

    await tester.tap(find.byKey(PaywallScreen.startTrialButtonKey));
    await tester.pumpAndSettle();

    // The fake flips to a premium-in-trial entitlement on buy.
    expect(billing.premiumStatus.isPremium, isTrue);
    expect(billing.premiumStatus.inTrial, isTrue);
  });

  testWidgets('Restore purchases invokes the service and surfaces a result',
      (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(PaywallScreen.restoreButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('Checked for previous purchases.'), findsOneWidget);
  });

  testWidgets('selecting the annual plan then buying purchases annual',
      (WidgetTester tester) async {
    final FakeBillingService billing = await _pump(tester);
    // Tap the annual plan card, then start the trial.
    await tester.tap(find.text('Holdclose Premium (Annual)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PaywallScreen.startTrialButtonKey));
    await tester.pumpAndSettle();
    expect(billing.premiumStatus.isPremium, isTrue);
  });

  testWidgets('an already-premium caregiver still sees the paywall + a note',
      (WidgetTester tester) async {
    await _pump(tester, initial: PremiumStatus.premium);
    expect(find.byKey(const Key('paywall-already-premium')), findsOneWidget);
    // Plans + CTA remain (reachable machinery).
    expect(find.byKey(PaywallScreen.startTrialButtonKey), findsOneWidget);
  });
}

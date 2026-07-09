import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/providers/billing_provider.dart';
import 'package:holdclose/screens/settings/paywall_screen.dart';
import 'package:holdclose/services/billing_service.dart';
import 'package:holdclose/widgets/premium_gate.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// [PremiumGate] shows its child only when entitled. NO current feature is
/// wrapped in it — this exercises the helper directly so the gate is proven
/// before pricing lands.
Future<void> _pump(
  WidgetTester tester, {
  required PremiumStatus status,
  Widget? locked,
}) async {
  final FakeBillingService billing = FakeBillingService(initialStatus: status);
  addTearDown(billing.dispose);

  final GoRouter router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) => Scaffold(
          body: PremiumGate(
            locked: locked,
            child: const Text('PREMIUM CONTENT'),
          ),
        ),
      ),
      GoRoute(
        path: '/premium',
        name: 'paywall',
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
}

void main() {
  testWidgets('shows the child when premium', (WidgetTester tester) async {
    await _pump(tester, status: PremiumStatus.premium);
    expect(find.text('PREMIUM CONTENT'), findsOneWidget);
  });

  testWidgets('hides the child and shows the default upsell when not premium',
      (WidgetTester tester) async {
    await _pump(tester, status: PremiumStatus.free);
    expect(find.text('PREMIUM CONTENT'), findsNothing);
    expect(find.textContaining('Holdclose Premium'), findsOneWidget);
  });

  testWidgets('renders a custom locked replacement when provided',
      (WidgetTester tester) async {
    await _pump(
      tester,
      status: PremiumStatus.free,
      locked: const Text('CUSTOM LOCKED'),
    );
    expect(find.text('PREMIUM CONTENT'), findsNothing);
    expect(find.text('CUSTOM LOCKED'), findsOneWidget);
  });

  testWidgets('default upsell routes to the paywall on tap',
      (WidgetTester tester) async {
    await _pump(tester, status: PremiumStatus.free);
    await tester.tap(find.textContaining('Holdclose Premium'));
    await tester.pumpAndSettle();
    // Landed on the paywall.
    expect(find.byKey(PaywallScreen.startTrialButtonKey), findsOneWidget);
  });
}

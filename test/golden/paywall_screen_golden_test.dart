import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/providers/billing_provider.dart';
import 'package:holdclose/screens/settings/paywall_screen.dart';
import 'package:holdclose/services/billing_service.dart';
import 'package:holdclose/theme.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI golden of the subscription paywall at `/premium`. Uses the
/// deterministic [FakeBillingService] (free entitlement, canned monthly +
/// annual plans, both carrying the free trial) so the render is stable
/// without a store. Follows the brand-theme golden convention.
Widget _host() {
  final FakeBillingService billing =
      FakeBillingService(initialStatus: PremiumStatus.free);

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

  return ProviderScope(
    overrides: <Override>[
      billingServiceProvider.overrideWithValue(billing),
    ],
    child: SizedBox(
      width: 420,
      height: 1200,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('PaywallScreen golden', () {
    goldenTest(
      'subscription paywall — value prop, plans, free-trial CTA',
      fileName: 'paywall_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'paywall (scaffold — no features gated)',
            child: _host(),
          ),
        ],
      ),
    );
  });
}

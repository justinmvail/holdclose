import 'package:alchemist/alchemist.dart';
import 'package:holdclose/l10n/app_localizations.dart';
import 'package:holdclose/screens/onboarding/welcome_carousel.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// CI golden of [WelcomeCarousel] at page 1 — the default-entry frame
/// the caregiver sees on first launch. We deliberately render via a
/// minimal router (rather than dropping a bare WelcomeCarousel widget)
/// so the AppBar's Skip action lands in its shipping shell and the
/// golden catches regressions in the page-view / dot indicator / CTA
/// stack.
void main() {
  group('WelcomeCarousel golden', () {
    goldenTest(
      'page 1 — brand logo + tagline + Next CTA + dots',
      fileName: 'welcome_carousel_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'page 1 (default entry)',
            child: ProviderScope(
              child: SizedBox(
                width: 390,
                height: 780,
                child: MaterialApp.router(
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  routerConfig: GoRouter(
                    initialLocation: '/onboarding',
                    routes: <RouteBase>[
                      GoRoute(
                        path: '/onboarding',
                        builder:
                            (BuildContext context, GoRouterState state) =>
                                const WelcomeCarousel(),
                      ),
                      GoRoute(
                        path: '/sign-in',
                        builder:
                            (BuildContext context, GoRouterState state) =>
                                const Scaffold(body: SizedBox.shrink()),
                      ),
                    ],
                  ),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: holdcloseColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

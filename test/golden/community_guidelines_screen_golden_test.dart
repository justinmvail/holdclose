import 'package:alchemist/alchemist.dart';
import 'package:holdclose/l10n/app_localizations.dart';
import 'package:holdclose/screens/community/community_guidelines_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI golden of the full-page community guidelines read at
/// `/community/guidelines` (BUILD_SPEC.md §13). The screen is a plain
/// layout over the locked `communityGuidelines` seed content; its chrome
/// strings come from the ARB-backed [AppLocalizations], so the host wires
/// the generated delegate + supported locales (as lib/app.dart does).
Widget _host() {
  final GoRouter router = GoRouter(
    initialLocation: '/community/guidelines',
    routes: <RouteBase>[
      GoRoute(
        path: '/community/guidelines',
        builder: (BuildContext context, GoRouterState state) =>
            const CommunityGuidelinesScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: const <Override>[],
    child: SizedBox(
      width: 420,
      height: 1400,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
  group('CommunityGuidelinesScreen golden', () {
    goldenTest(
      'full-page guidelines read — four section cards',
      fileName: 'community_guidelines_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'guidelines (full page)',
            child: _host(),
          ),
        ],
      ),
    );
  });
}

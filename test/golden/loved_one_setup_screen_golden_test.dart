import 'package:alchemist/alchemist.dart';
import 'package:careblazers/l10n/app_localizations.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/onboarding/loved_one_setup_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI golden of [LovedOneSetupScreen] — the new-user setup wizard the
/// caregiver lands on after sign-in when no loved one is on file yet.
/// Rendered via a minimal router (with a `/` stub the save would land
/// on) inside the brand background, so the golden catches regressions in
/// the warm intro + the essentials form stack.
Widget _host() {
  final GoRouter router = GoRouter(
    initialLocation: '/setup',
    routes: <RouteBase>[
      GoRoute(
        path: '/setup',
        builder: (BuildContext context, GoRouterState state) =>
            const LovedOneSetupScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      storageProvider.overrideWithValue(InMemoryStorageProvider()),
      patientSetupIdFactoryProvider.overrideWithValue(() => 'golden-id'),
    ],
    child: SizedBox(
      width: 420,
      height: 1500,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('LovedOneSetupScreen golden', () {
    goldenTest(
      'new-user setup wizard — essentials form',
      fileName: 'loved_one_setup_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'setup wizard (empty)',
            child: _host(),
          ),
        ],
      ),
    );
  });
}

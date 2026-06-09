import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:careblazers/l10n/app_localizations.dart';
import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/screens/onboarding/sign_in_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Stub [AuthProvider] for the golden — never throws, never emits, just
/// holds at signedOut so the screen renders its idle state. The real
/// [RealAuthProvider.production] factory works in tests too (its
/// constructor defers platform calls), but pinning a stub here keeps
/// the golden deterministic in case a future factory change starts
/// touching channels eagerly.
class _GoldenAuthStub implements AuthProvider {
  const _GoldenAuthStub();

  @override
  Stream<AuthState> watchAuthState() async* {
    yield const AuthState.signedOut();
  }

  @override
  Future<void> signInWithApple() async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async {}
}

/// CI golden — sign-in screen on iOS (the case that renders the Apple
/// button alongside the Google one). We deliberately pump on iOS so the
/// golden captures both OAuth affordances; the Android case (no Apple
/// button) is asserted in the widget tests.
void main() {
  group('SignInScreen golden', () {
    goldenTest(
      'iOS — Apple + Google + terms line',
      fileName: 'sign_in_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'iOS (Apple + Google visible)',
            child: ProviderScope(
              overrides: <Override>[
                authProvider.overrideWithValue(const _GoldenAuthStub()),
              ],
              child: SizedBox(
                width: 390,
                height: 780,
                child: MaterialApp.router(
                  theme: ThemeData(platform: TargetPlatform.iOS),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  routerConfig: GoRouter(
                    initialLocation: '/sign-in',
                    routes: <RouteBase>[
                      GoRoute(
                        path: '/sign-in',
                        builder:
                            (BuildContext context, GoRouterState state) =>
                                const SignInScreen(),
                      ),
                      GoRoute(
                        path: '/',
                        builder:
                            (BuildContext context, GoRouterState state) =>
                                const Scaffold(body: SizedBox.shrink()),
                      ),
                    ],
                  ),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.background,
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

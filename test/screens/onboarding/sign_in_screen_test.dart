import 'dart:async';

import 'package:holdclose/l10n/app_localizations.dart';
import 'package:holdclose/providers/auth_provider.dart';
import 'package:holdclose/providers/loved_one_lookup_provider.dart';
import 'package:holdclose/providers/settings_provider.dart';
import 'package:holdclose/screens/onboarding/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

import '../_semantics_matchers.dart';

/// Spy [AuthProvider] that counts how many times each sign-in method
/// got called and exposes the [AuthState] stream the screen subscribes
/// to. Lets the tests assert "the button tap reached the provider"
/// without exercising the real OAuth plugins.
class _SpyAuthProvider implements AuthProvider {
  _SpyAuthProvider({this.shouldThrow = false});

  int appleCalls = 0;
  int googleCalls = 0;
  bool shouldThrow;
  AuthState _state = const AuthState.signedOut();
  final StreamController<AuthState> _changes =
      StreamController<AuthState>.broadcast();

  static const User _user = User(
    id: 'spy-user',
    email: 'spy@holdclose.app',
    name: 'Spy Caregiver',
  );

  Future<void> dispose() => _changes.close();

  @override
  Stream<AuthState> watchAuthState() async* {
    yield _state;
    yield* _changes.stream;
  }

  @override
  Future<void> signInWithApple() async {
    appleCalls += 1;
    if (shouldThrow) {
      _emit(const AuthState.signedOut());
      throw StateError('apple failed');
    }
    _emit(const AuthState.signedIn(user: _user));
  }

  @override
  Future<void> signInWithGoogle() async {
    googleCalls += 1;
    if (shouldThrow) {
      _emit(const AuthState.signedOut());
      throw StateError('google failed');
    }
    _emit(const AuthState.signedIn(user: _user));
  }

  @override
  Future<void> signOut() async => _emit(const AuthState.signedOut());

  @override
  Future<void> deleteAccount() async => _emit(const AuthState.signedOut());

  void _emit(AuthState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }
}

/// No-op [LovedOneLookup] for the sign-in SCREEN tests. The real notifier's
/// `adopt()` reaches into the sync engine (opening a drift database + a poll
/// timer) — irrelevant to the screen's UI/routing contract and unsafe in a
/// bare widget test. The post-sign-in backend lookup itself is covered by
/// `test/providers/loved_one_lookup_provider_test.dart` and the router's
/// pending-gate tests.
class _NoopLovedOneLookup extends LovedOneLookup {
  @override
  Future<void> adopt() async {}
}

/// Pump the sign-in screen inside a minimal router with a `/` stub.
/// Tests assert routing by inspecting the router delegate's current
/// path and the presence of the stub's marker text.
Future<({_SpyAuthProvider spy, GoRouter router})> _pumpSignIn(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  _SpyAuthProvider? spy,
  bool alphaMode = false,
  bool showGoogleInAlpha = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final _SpyAuthProvider auth = spy ?? _SpyAuthProvider();
  addTearDown(auth.dispose);

  final GoRouter router = GoRouter(
    initialLocation: '/sign-in',
    routes: <RouteBase>[
      GoRoute(
        path: '/sign-in',
        builder: (BuildContext context, GoRouterState state) =>
            SignInScreen(
          alphaMode: alphaMode,
          showGoogleInAlpha: showGoogleInAlpha,
        ),
      ),
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('test-home'))),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        authProvider.overrideWithValue(auth),
        // The screen's post-sign-in loved-one lookup reaches into the sync
        // engine; stub it out so these UI/routing tests stay hermetic.
        lovedOneLookupProvider.overrideWith(_NoopLovedOneLookup.new),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: platform),
        // The screen reads chrome strings via AppLocalizations.of (#18
        // localization); register the generated delegate + supportedLocales
        // so `.of(context)` resolves (nullable-getter: false).
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (spy: auth, router: router);
}

void main() {
  group('SignInScreen — BUILD_SPEC.md §5.12 layout', () {
    testWidgets('renders Holdclose wordmark + tagline',
        (WidgetTester tester) async {
      await _pumpSignIn(tester);

      expect(find.text('Holdclose'), findsOneWidget);
      expect(find.text(SignInScreen.tagline), findsOneWidget);
    });

    testWidgets('AppBar has no back button (top-of-stack route)',
        (WidgetTester tester) async {
      await _pumpSignIn(tester);

      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('Google button renders on Android', (WidgetTester tester) async {
      await _pumpSignIn(tester, platform: TargetPlatform.android);

      expect(find.byKey(SignInScreen.googleButtonKey), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
    });

    testWidgets('Google button renders on iOS too', (WidgetTester tester) async {
      await _pumpSignIn(tester, platform: TargetPlatform.iOS);

      expect(find.byKey(SignInScreen.googleButtonKey), findsOneWidget);
    });

    testWidgets('Apple button is hidden on non-iOS platforms',
        (WidgetTester tester) async {
      await _pumpSignIn(tester, platform: TargetPlatform.android);

      expect(find.byKey(SignInScreen.appleButtonKey), findsNothing);
      expect(find.text('Continue with Apple'), findsNothing);
    });

    testWidgets('Apple button shows only on iOS', (WidgetTester tester) async {
      await _pumpSignIn(tester, platform: TargetPlatform.iOS);

      expect(find.byKey(SignInScreen.appleButtonKey), findsOneWidget);
      expect(find.text('Continue with Apple'), findsOneWidget);
    });

    testWidgets('Terms + Privacy Policy lines render',
        (WidgetTester tester) async {
      await _pumpSignIn(tester);

      expect(find.textContaining('By continuing, you agree to our'),
          findsOneWidget);
      expect(find.byKey(SignInScreen.termsLinkKey), findsOneWidget);
      expect(find.byKey(SignInScreen.privacyLinkKey), findsOneWidget);
    });
  });

  group('SignInScreen — DEMO_MODE skip-button visibility (§5.12)', () {
    testWidgets(
      'demo-skip button is hidden without --dart-define=DEMO_MODE=true',
      (WidgetTester tester) async {
        // The widget-test harness is compiled without the DEMO_MODE
        // define, so [demoModeEnabled] is false and the skip button
        // must NOT render. This is the inverse of the demo-mode tests
        // that run under `flutter test integration_test/demo_tour.dart
        // --dart-define=DEMO_MODE=true`.
        await _pumpSignIn(tester);

        expect(demoModeEnabled, isFalse,
            reason: 'sanity: test harness has no DEMO_MODE define');
        expect(find.byKey(SignInScreen.demoSkipButtonKey), findsNothing);
        expect(find.textContaining("Skip — explore"), findsNothing);
      },
    );
  });

  group('SignInScreen — provider wiring (§5.12 state)', () {
    testWidgets('tapping Google calls signInWithGoogle on the provider',
        (WidgetTester tester) async {
      final ({_SpyAuthProvider spy, GoRouter router}) pumped =
          await _pumpSignIn(tester);

      expect(pumped.spy.googleCalls, 0);

      await tester.tap(find.byKey(SignInScreen.googleButtonKey));
      await tester.pumpAndSettle();

      expect(pumped.spy.googleCalls, 1);
      expect(pumped.spy.appleCalls, 0,
          reason: 'Google tap must not trigger the Apple flow');
    });

    testWidgets('tapping Apple calls signInWithApple on the provider',
        (WidgetTester tester) async {
      final ({_SpyAuthProvider spy, GoRouter router}) pumped =
          await _pumpSignIn(tester, platform: TargetPlatform.iOS);

      await tester.tap(find.byKey(SignInScreen.appleButtonKey));
      await tester.pumpAndSettle();

      expect(pumped.spy.appleCalls, 1);
      expect(pumped.spy.googleCalls, 0,
          reason: 'Apple tap must not trigger the Google flow');
    });

    testWidgets('successful sign-in routes to /', (WidgetTester tester) async {
      final ({_SpyAuthProvider spy, GoRouter router}) pumped =
          await _pumpSignIn(tester);

      expect(find.text('test-home'), findsNothing);

      await tester.tap(find.byKey(SignInScreen.googleButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('test-home'), findsOneWidget);
      expect(
        pumped.router.routerDelegate.currentConfiguration.uri.path,
        '/',
      );
    });

    testWidgets('flow throwing surfaces an error banner + stays on screen',
        (WidgetTester tester) async {
      final _SpyAuthProvider spy = _SpyAuthProvider(shouldThrow: true);
      final ({_SpyAuthProvider spy, GoRouter router}) pumped =
          await _pumpSignIn(tester, spy: spy);

      await tester.tap(find.byKey(SignInScreen.googleButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(SignInScreen.errorBannerKey), findsOneWidget);
      expect(find.textContaining("Couldn't sign in"), findsOneWidget);
      expect(
        pumped.router.routerDelegate.currentConfiguration.uri.path,
        '/sign-in',
        reason: 'failed sign-in must not leave the screen',
      );
    });
  });

  group('SignInScreen — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets('Apple + Google buttons announce their purpose',
        (WidgetTester tester) async {
      await _pumpSignIn(tester, platform: TargetPlatform.iOS);

      expect(
        hasSemanticsLabel(tester, RegExp('Continue with Apple')),
        isTrue,
      );
      expect(
        hasSemanticsLabel(tester, RegExp('Continue with Google')),
        isTrue,
      );
    });
  });

  group('SignInScreen — alpha tester (Google-only)', () {
    testWidgets(
        'alpha mode (Google configured) shows ONLY the Google button',
        (WidgetTester tester) async {
      await _pumpSignIn(
        tester,
        alphaMode: true,
        showGoogleInAlpha: true,
        platform: TargetPlatform.iOS,
      );

      expect(find.byKey(SignInScreen.alphaGoogleButtonKey), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      // No bypass: no name field, no Continue button, no Apple button, no
      // unavailable message.
      expect(find.byKey(SignInScreen.appleButtonKey), findsNothing);
      expect(find.byKey(SignInScreen.alphaUnavailableKey), findsNothing);
      // Terms line still renders under the button.
      expect(find.byKey(SignInScreen.termsLinkKey), findsOneWidget);
    });

    testWidgets(
        'alpha mode (Google NOT configured) shows the unavailable message, '
        'no bypass', (WidgetTester tester) async {
      await _pumpSignIn(tester, alphaMode: true, platform: TargetPlatform.iOS);

      expect(find.byKey(SignInScreen.alphaUnavailableKey), findsOneWidget);
      expect(find.textContaining("isn't available"), findsOneWidget);
      // No actionable affordance of any kind.
      expect(find.byKey(SignInScreen.alphaGoogleButtonKey), findsNothing);
      expect(find.byKey(SignInScreen.googleButtonKey), findsNothing);
      expect(find.byKey(SignInScreen.appleButtonKey), findsNothing);
    });

    testWidgets('tapping the alpha Google button runs the real Google flow',
        (WidgetTester tester) async {
      final ({_SpyAuthProvider spy, GoRouter router}) pumped = await _pumpSignIn(
        tester,
        alphaMode: true,
        showGoogleInAlpha: true,
      );

      await tester.tap(find.byKey(SignInScreen.alphaGoogleButtonKey));
      await tester.pumpAndSettle();

      expect(pumped.spy.googleCalls, 1); // the backend-verified Google path
      expect(find.text('test-home'), findsOneWidget); // routed home
    });
  });
}

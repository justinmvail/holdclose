import 'dart:async';

import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/providers/onboarding_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/crisis/crisis_card_screen.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:careblazers/screens/library/library_screen.dart';
import 'package:careblazers/screens/onboarding/sign_in_screen.dart';
import 'package:careblazers/screens/onboarding/welcome_carousel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pump the router wrapped in a bare MaterialApp + a ProviderScope.
/// We deliberately skip `careblazersLightTheme` here — its google_fonts
/// TextStyles fire fire-and-forget Futures during construction; in
/// unit tests without bundled font assets those Futures fail in the
/// root zone and surface as uncaught errors. The theme contract is
/// owned by theme_test.dart; here we only care about route
/// registration.
///
/// The ProviderScope is required because screens that watch riverpod
/// providers (Journal → `journalEntriesProvider`,
/// `patternDetectorProvider`) crash without one — these registration
/// tests probe every route, so the scope has to cover them all.
Future<GoRouter> pumpRouter(
  WidgetTester tester, {
  String initialLocation = '/',
}) async {
  final GoRouter router = buildRouter(initialLocation: initialLocation);
  await tester.pumpWidget(
    ProviderScope(child: MaterialApp.router(routerConfig: router)),
  );
  await tester.pumpAndSettle();
  return router;
}

String currentPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

void main() {
  group('careblazersRouter — BUILD_SPEC.md §5 registration', () {
    // Every path BUILD_SPEC.md §5 names. Dynamic-segment routes are
    // probed with a sample id so we exercise the parameterised path.
    const Map<String, String> sectionPaths = <String, String>{
      '§5.1 Home': '/',
      '§5.2 Behavior picker': '/decoder/behavior',
      '§5.3 Triage': '/decoder/triage',
      '§5.4 Decoder result': '/decoder/result',
      '§5.5 Journal': '/journal',
      '§5.6 Journal entry detail': '/journal/sample-id',
      '§5.7 Library': '/library',
      '§5.8 Library card detail': '/library/anosognosia',
      '§5.9 Crisis card': '/crisis',
      '§5.10 Settings': '/settings',
      '§5.11 Welcome carousel': '/onboarding',
      '§5.12 Sign-in': '/sign-in',
    };

    sectionPaths.forEach((String section, String path) {
      testWidgets('$section registered at $path', (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);
        router.go(path);
        await tester.pumpAndSettle();

        expect(
          currentPath(router),
          path,
          reason: '$section ($path) did not register; router stayed at '
              '${currentPath(router)}',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$section ($path) threw on navigation',
        );
      });
    });
  });

  group('careblazersRouter — tab shell', () {
    testWidgets(
      'opens on Home (§5.1) by default with the four-tab NavigationBar',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        expect(currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsOneWidget);
        // Tab labels appear in the exact §4.1 order.
        expect(find.text('Home'), findsOneWidget);
        expect(find.text('Journal'), findsOneWidget);
        expect(find.text('Library'), findsOneWidget);
        expect(find.text('Crisis'), findsOneWidget);
      },
    );

    testWidgets(
      'tab-bar tap switches branches via context.go',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        await tester.tap(find.byIcon(Icons.book_outlined));
        await tester.pumpAndSettle();
        expect(currentPath(router), '/journal');
        expect(find.byType(JournalScreen), findsOneWidget);

        await tester.tap(find.byIcon(Icons.library_books_outlined));
        await tester.pumpAndSettle();
        expect(currentPath(router), '/library');
        expect(find.byType(LibraryScreen), findsOneWidget);

        await tester.tap(find.byIcon(Icons.warning_amber_outlined));
        await tester.pumpAndSettle();
        expect(currentPath(router), '/crisis');
        expect(find.byType(CrisisCardScreen), findsOneWidget);

        // Selected icon is `home` (filled variant) once we land back
        // on the Home branch; we tap the outlined Journal icon first
        // to leave Home, then return via the now-outlined Home icon.
        await tester.tap(find.byIcon(Icons.home_outlined));
        await tester.pumpAndSettle();
        expect(currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
      },
    );
  });

  group('careblazersRouter — push from Home', () {
    testWidgets(
      'Home → /decoder/behavior via context.push leaves a back arrow',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        // Root of the Home tab has no back arrow.
        expect(find.byType(BackButton), findsNothing);

        // `push` returns a Future that completes only when the route
        // is popped — we'll pop it ourselves below, so don't await.
        // Note: `push` adds an imperative match on top of the current
        // RouteMatchList. go_router doesn't roll the displayed URL
        // forward for imperative pushes (the URL still reads `/`),
        // so we assert navigation by what the user actually sees:
        // the BehaviorPickerScreen and the auto-rendered back arrow.
        unawaited(router.push('/decoder/behavior'));
        await tester.pumpAndSettle();

        expect(find.byType(BehaviorPickerScreen), findsOneWidget);
        expect(
          find.byType(BackButton),
          findsOneWidget,
          reason: 'pushed routes must auto-render a back arrow',
        );
        // The pushed route covers the tab shell.
        expect(find.byType(NavigationBar), findsNothing);

        // Tapping the back arrow pops the push and returns to Home.
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byType(BehaviorPickerScreen), findsNothing);
        expect(currentPath(router), '/');
      },
    );
  });

  group('careblazersRedirect — pure policy (BUILD_SPEC.md §5.11 + §5.12)', () {
    const AuthState signedOut = AuthState.signedOut();
    const AuthState signedIn = AuthState.signedIn(
      user: User(
        id: 'redirect-test',
        email: 'redirect@careblazers.app',
        name: 'Redirect Test',
      ),
    );
    const AuthState loading = AuthState.loading();

    test('un-onboarded + signed-out funnels everything to /onboarding', () {
      expect(
        careblazersRedirect(
          location: '/',
          onboardingCompleted: false,
          authState: signedOut,
        ),
        '/onboarding',
      );
      expect(
        careblazersRedirect(
          location: '/journal',
          onboardingCompleted: false,
          authState: signedOut,
        ),
        '/onboarding',
      );
      expect(
        careblazersRedirect(
          location: '/sign-in',
          onboardingCompleted: false,
          authState: signedOut,
        ),
        '/onboarding',
        reason: 'sign-in is gated behind onboarding — bounce back to '
            'the carousel until it completes',
      );
    });

    test(
      '/onboarding returns null when onboarding incomplete (no loop)',
      () {
        // The redirect MUST return null when the user is already on the
        // gate's target location — otherwise go_router treats the
        // decision as unstable and bails after its safety limit.
        expect(
          careblazersRedirect(
            location: '/onboarding',
            onboardingCompleted: false,
            authState: signedOut,
          ),
          isNull,
        );
      },
    );

    test('onboarded + signed-out funnels everything to /sign-in', () {
      expect(
        careblazersRedirect(
          location: '/',
          onboardingCompleted: true,
          authState: signedOut,
        ),
        '/sign-in',
      );
      expect(
        careblazersRedirect(
          location: '/journal',
          onboardingCompleted: true,
          authState: signedOut,
        ),
        '/sign-in',
      );
      expect(
        careblazersRedirect(
          location: '/onboarding',
          onboardingCompleted: true,
          authState: signedOut,
        ),
        '/sign-in',
        reason: 'onboarded users never need to see the carousel again',
      );
    });

    test('/sign-in returns null when onboarded + signed-out (no loop)', () {
      expect(
        careblazersRedirect(
          location: '/sign-in',
          onboardingCompleted: true,
          authState: signedOut,
        ),
        isNull,
      );
    });

    test('auth loading state is treated as signed-out (gates to /sign-in)', () {
      // While the OAuth round-trip is in flight the auth machine reads
      // [AuthStateLoading]. The redirect must NOT bounce the user off
      // `/sign-in` mid-flow — treat anything that isn't explicitly
      // signedIn as signedOut.
      expect(
        careblazersRedirect(
          location: '/sign-in',
          onboardingCompleted: true,
          authState: loading,
        ),
        isNull,
      );
      expect(
        careblazersRedirect(
          location: '/',
          onboardingCompleted: true,
          authState: loading,
        ),
        '/sign-in',
      );
    });

    test('signed-in user can navigate anywhere outside the auth screens', () {
      expect(
        careblazersRedirect(
          location: '/',
          onboardingCompleted: true,
          authState: signedIn,
        ),
        isNull,
      );
      expect(
        careblazersRedirect(
          location: '/journal',
          onboardingCompleted: true,
          authState: signedIn,
        ),
        isNull,
      );
      expect(
        careblazersRedirect(
          location: '/decoder/result',
          onboardingCompleted: true,
          authState: signedIn,
        ),
        isNull,
      );
    });

    test(
      'signed-in user bounced off /onboarding + /sign-in back to /',
      () {
        // Deep links or browser back can land a signed-in caregiver on
        // an auth screen — kick them home rather than asking them to
        // re-onboard.
        expect(
          careblazersRedirect(
            location: '/onboarding',
            onboardingCompleted: true,
            authState: signedIn,
          ),
          '/',
        );
        expect(
          careblazersRedirect(
            location: '/sign-in',
            onboardingCompleted: true,
            authState: signedIn,
          ),
          '/',
        );
      },
    );
  });

  group('careblazersRouterProvider — wired redirect (task 31)', () {
    testWidgets(
      'unauthenticated + un-onboarded app lands on /onboarding',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(420, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final _RedirectSpyAuth auth = _RedirectSpyAuth();
        addTearDown(auth.dispose);

        await _pumpWiredRouter(tester, auth: auth);

        // Even though the wired router's `initialLocation` is `/`, the
        // redirect policy collapses everything to `/onboarding` until
        // the carousel finishes.
        expect(find.byType(WelcomeCarousel), findsOneWidget);
        expect(find.byType(HomeScreen), findsNothing);
      },
    );

    testWidgets(
      'tapping Skip from /onboarding lands on /sign-in',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(420, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final _RedirectSpyAuth auth = _RedirectSpyAuth();
        addTearDown(auth.dispose);

        await _pumpWiredRouter(tester, auth: auth);

        expect(find.byType(WelcomeCarousel), findsOneWidget);

        await tester.tap(find.byKey(WelcomeCarousel.skipButtonKey));
        await tester.pumpAndSettle();

        // Skip routes to `/sign-in` (carousel does `context.go`); the
        // auth gate keeps the user there since `signedOut` is still
        // active and onboarding's `complete()` hasn't fired.
        expect(find.byType(SignInScreen), findsOneWidget);
        expect(find.byType(WelcomeCarousel), findsNothing);
      },
    );

    testWidgets(
      'after onboarding + fake sign-in, lands on / (home tab visible)',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(420, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final _RedirectSpyAuth auth = _RedirectSpyAuth();
        addTearDown(auth.dispose);

        final ProviderContainer container = await _pumpWiredRouter(
          tester,
          auth: auth,
        );

        // Walk the carousel to its end so `onboardingCompletedProvider`
        // flips true — this is the same path the carousel test
        // exercises for the welcome flow, here in service of the
        // redirect.
        for (int i = 0; i < WelcomeCarousel.pages.length; i++) {
          await tester.tap(find.byKey(WelcomeCarousel.primaryCtaKey));
          await tester.pumpAndSettle();
        }

        expect(container.read(onboardingCompletedProvider), isTrue);
        expect(find.byType(SignInScreen), findsOneWidget);

        // Fake the OAuth completion — the wired router's
        // refreshListenable will fire and re-evaluate the redirect.
        auth.simulateSignIn();
        await tester.pumpAndSettle();

        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsOneWidget,
            reason: 'tab bar must be visible once the user lands on /');
      },
    );
  });
}

/// Test [AuthProvider] that lets the test drive the state machine via
/// [simulateSignIn] / [simulateSignOut]. Mirrors the spy pattern used
/// by `test/screens/onboarding/sign_in_screen_test.dart` but tailored
/// to the redirect tests (which don't care about call-count tracking).
class _RedirectSpyAuth implements AuthProvider {
  _RedirectSpyAuth();

  static const User _user = User(
    id: 'redirect-spy-user',
    email: 'spy@careblazers.app',
    name: 'Spy Caregiver',
  );

  AuthState _state = const AuthState.signedOut();
  final StreamController<AuthState> _changes =
      StreamController<AuthState>.broadcast();

  Future<void> dispose() => _changes.close();

  @override
  Stream<AuthState> watchAuthState() async* {
    yield _state;
    yield* _changes.stream;
  }

  @override
  Future<void> signInWithApple() async => simulateSignIn();

  @override
  Future<void> signInWithGoogle() async => simulateSignIn();

  @override
  Future<void> signOut() async => simulateSignOut();

  @override
  Future<void> deleteAccount() async => simulateSignOut();

  void simulateSignIn() => _emit(const AuthState.signedIn(user: _user));

  void simulateSignOut() => _emit(const AuthState.signedOut());

  void _emit(AuthState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }
}

/// Pump [careblazersRouterProvider] inside a real `MaterialApp.router`
/// with auth overridden to [auth]. Returns the [ProviderContainer] so
/// tests can read [onboardingCompletedProvider] without going through
/// the widget tree.
Future<ProviderContainer> _pumpWiredRouter(
  WidgetTester tester, {
  required _RedirectSpyAuth auth,
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      authBackendProvider.overrideWithValue(auth),
    ],
  );
  addTearDown(container.dispose);

  final GoRouter router = container.read(careblazersRouterProvider);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

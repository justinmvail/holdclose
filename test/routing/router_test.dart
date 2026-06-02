import 'dart:async';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/providers/home_conversation_provider.dart';
import 'package:careblazers/providers/onboarding_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/appointment/appointment_list_screen.dart';
import 'package:careblazers/screens/chat/conversation_list_screen.dart';
import 'package:careblazers/screens/community/community_feed_screen.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/medical/emergency_card_screen.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/screens/team/care_team_hub_screen.dart';
import 'package:careblazers/screens/medication/medication_list_screen.dart';
import 'package:careblazers/screens/onboarding/sign_in_screen.dart';
import 'package:careblazers/screens/onboarding/welcome_carousel.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:drift/native.dart';
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
/// owned by theme_test.dart; here we only care about navigation
/// behaviour.
///
/// Used by the behavioural groups (tab switching, push semantics, the
/// crisis redirect) which actually mount screens. The exhaustive
/// path-resolution table lives in the `namedLocation` group below — it
/// needs no widget tree, so it never trips the FakeAsync pending-timer
/// assertion that live drift query streams would otherwise raise.
///
/// The ProviderScope is required because the shell branches watch
/// riverpod providers (Home → `homeConversationProvider`, Chat →
/// `chatRepositoryProvider`, Community → `forumApiClientProvider`). The
/// chat repository is backed by an in-memory drift database so the Chat
/// branch resolves deterministically; the community feed falls through
/// to the demo (in-memory) forum client the default settings select.
Future<GoRouter> pumpRouter(
  WidgetTester tester, {
  String initialLocation = '/',
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = buildRouter(initialLocation: initialLocation);
  final DateTime now = DateTime.utc(2026, 5, 30, 12);
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        // HomeScreen builds via homeConversationProvider; route-only
        // tests don't stand up a real drift database, so we hand the
        // home tab a synthetic conversation that lets it render the
        // chat scaffold without hitting storage.
        homeConversationProvider.overrideWith(
          (_) async => Conversation(
            id: 'route-test-conv',
            title: 'Today',
            createdAt: now,
            updatedAt: now,
          ),
        ),
        // Chat branch (/chat + /chat/:id) reads the repository through a
        // one-shot FutureProvider; back it with an in-memory database so
        // the list + thread render deterministically. The other
        // storage-backed routes are exercised by `namedLocation` (no
        // widget mount) precisely BECAUSE rendering a live drift query
        // stream inside the FakeAsync test zone leaves a pending timer.
        chatRepositoryProvider.overrideWith((_) => ChatRepository(db)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String currentPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

/// One named-route expectation: the [CareblazersRoutes] name, the
/// path parameters to fill, and the location it must resolve to.
class _NamedRoute {
  const _NamedRoute(this.name, this.location, [this.params = const {}]);
  final String name;
  final String location;
  final Map<String, String> params;
}

void main() {
  group('careblazersRouter — route registration (old + Phase 14 IA)', () {
    // Exhaustive check that every registered route — carried over from
    // earlier phases AND added/moved in the Phase 14.5 rewrite — resolves
    // by name to the expected location. `namedLocation` is a pure lookup
    // against the route table, so it covers the storage-backed feature
    // routes (medication/appointment forms, journal) that can't be safely
    // *rendered* in a unit test without leaving a drift query-stream timer
    // pending. The go()-based behavioural groups below cover the screens
    // that DO render cleanly.
    const List<_NamedRoute> registered = <_NamedRoute>[
      // Carried over from earlier phases.
      _NamedRoute(CareblazersRoutes.home, '/'),
      _NamedRoute(CareblazersRoutes.decoderBehavior, '/decoder/behavior'),
      _NamedRoute(CareblazersRoutes.decoderTriage, '/decoder/triage'),
      _NamedRoute(CareblazersRoutes.decoderResult, '/decoder/result'),
      _NamedRoute(CareblazersRoutes.settings, '/settings'),
      _NamedRoute(CareblazersRoutes.onboarding, '/onboarding'),
      _NamedRoute(CareblazersRoutes.signIn, '/sign-in'),
      // Journal — moved to top-level pushed routes in Phase 14.5.
      _NamedRoute(CareblazersRoutes.journal, '/journal'),
      _NamedRoute(CareblazersRoutes.journalNew, '/journal/new'),
      _NamedRoute(CareblazersRoutes.journalEntry, '/journal/sample-id',
          <String, String>{'id': 'sample-id'}),
      // Medications — moved to top-level pushed routes in Phase 14.5.
      _NamedRoute(CareblazersRoutes.medicationList, '/medications'),
      _NamedRoute(CareblazersRoutes.medicationForm, '/medications/new'),
      _NamedRoute(CareblazersRoutes.medicationEdit,
          '/medications/sample-id/edit', <String, String>{'id': 'sample-id'}),
      _NamedRoute(CareblazersRoutes.medicationDoseLog, '/medications/today'),
      // Appointments — moved to top-level pushed routes in Phase 14.5.
      _NamedRoute(CareblazersRoutes.appointmentList, '/appointments'),
      _NamedRoute(CareblazersRoutes.appointmentForm, '/appointments/new'),
      _NamedRoute(CareblazersRoutes.appointmentDetail,
          '/appointments/sample-id', <String, String>{'id': 'sample-id'}),
      _NamedRoute(CareblazersRoutes.appointmentEdit,
          '/appointments/sample-id/edit', <String, String>{'id': 'sample-id'}),
      // Community shell branch + its pushed companions.
      _NamedRoute(CareblazersRoutes.community, '/community'),
      _NamedRoute(CareblazersRoutes.communityCompose, '/community/compose'),
      _NamedRoute(
          CareblazersRoutes.communityGuidelines, '/community/guidelines'),
      _NamedRoute(
          CareblazersRoutes.communityAdminReports, '/community/admin/reports'),
      _NamedRoute(CareblazersRoutes.communityPostDetail,
          '/community/sample-post', <String, String>{'postId': 'sample-post'}),
      // New Phase 14 shell branches + the Medical emergency sub-route.
      _NamedRoute(CareblazersRoutes.medicalHub, '/medical'),
      _NamedRoute(
          CareblazersRoutes.medicalCardsEmergency, '/medical/cards/emergency'),
      _NamedRoute(CareblazersRoutes.medicalCardsEmergencyEdit,
          '/medical/cards/emergency/edit'),
      _NamedRoute(CareblazersRoutes.teamHub, '/team'),
      _NamedRoute(CareblazersRoutes.chatList, '/chat'),
      _NamedRoute(CareblazersRoutes.chatThread, '/chat/sample-id',
          <String, String>{'id': 'sample-id'}),
      // `/crisis` stays registered for deep-link compat (it redirects at
      // navigation time — see the behavioural group below).
      _NamedRoute(CareblazersRoutes.crisis, '/crisis'),
    ];

    for (final _NamedRoute route in registered) {
      test('${route.name} resolves to ${route.location}', () {
        final GoRouter router = buildRouter();
        addTearDown(router.dispose);
        expect(
          router.namedLocation(route.name, pathParameters: route.params),
          route.location,
        );
      });
    }
  });

  group('careblazersRouter — fixed 5-tab shell', () {
    testWidgets(
      'opens on Home by default inside the tab shell',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        expect(currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsOneWidget);
      },
    );

    testWidgets(
      'context.go switches between the five shell branches, tab bar persists',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        // Medical branch — the tile hub (Phase 14.15).
        router.go('/medical');
        await tester.pumpAndSettle();
        expect(currentPath(router), '/medical');
        expect(find.byType(MedicalHubScreen), findsOneWidget);
        expect(
          find.byType(NavigationBar),
          findsOneWidget,
          reason: 'a shell branch keeps the bottom tab bar visible',
        );

        // Care Team branch — the tile hub (Phase 14.26).
        router.go('/team');
        await tester.pumpAndSettle();
        expect(currentPath(router), '/team');
        expect(find.byType(CareTeamHubScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsOneWidget);

        // Chat branch — direct landing.
        router.go('/chat');
        await tester.pumpAndSettle();
        expect(currentPath(router), '/chat');
        expect(find.byType(ConversationListScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsOneWidget);

        // Community branch — direct landing.
        router.go('/community');
        await tester.pumpAndSettle();
        expect(currentPath(router), '/community');
        expect(find.byType(CommunityFeedScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsOneWidget);

        // Back to Home.
        router.go('/');
        await tester.pumpAndSettle();
        expect(currentPath(router), '/');
        expect(find.byType(HomeScreen), findsOneWidget);
      },
    );

    testWidgets(
      '/chat/:id pushes onto the Chat branch navigator (tab bar stays)',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        router.go('/chat');
        await tester.pumpAndSettle();
        expect(find.byType(ConversationListScreen), findsOneWidget);

        // A thread is a child of the Chat branch with no
        // `parentNavigatorKey`, so it pushes onto the branch navigator
        // — the bottom tab bar must remain visible, unlike a root-
        // pushed feature route which covers the whole shell.
        unawaited(router.push('/chat/sample-id'));
        await tester.pumpAndSettle();

        expect(
          find.byType(NavigationBar),
          findsOneWidget,
          reason: 'a thread pushed onto the branch navigator keeps the '
              'tab bar',
        );
        expect(find.byType(ConversationListScreen), findsNothing);
      },
    );

    testWidgets(
      '/crisis redirects to the canonical Emergency Card location',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        router.go('/crisis');
        await tester.pumpAndSettle();

        expect(currentPath(router), '/medical/cards/emergency');
        expect(find.byType(EmergencyCardScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('careblazersRouter — push semantics on the moved feature routes', () {
    testWidgets(
      'pushing /medications covers the shell + leaves a back arrow',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        // Root of the Home tab has no back arrow + shows the tab bar.
        expect(find.byType(BackButton), findsNothing);
        expect(find.byType(NavigationBar), findsOneWidget);

        // `push` adds an imperative match on top of the current stack;
        // go_router doesn't roll the displayed URL forward for
        // imperative pushes, so we assert by what the user sees: the
        // MedicationListScreen, the auto-rendered back arrow, and the
        // covered tab bar (the route pushes onto the ROOT navigator).
        unawaited(router.push('/medications'));
        await tester.pumpAndSettle();

        expect(find.byType(MedicationListScreen), findsOneWidget);
        expect(
          find.byType(BackButton),
          findsOneWidget,
          reason: 'root-pushed feature routes auto-render a back arrow',
        );
        expect(
          find.byType(NavigationBar),
          findsNothing,
          reason: 'a root-pushed feature route covers the tab shell',
        );

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byType(MedicationListScreen), findsNothing);
        expect(currentPath(router), '/');
      },
    );

    testWidgets(
      'pushing /appointments covers the shell + leaves a back arrow',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        unawaited(router.push('/appointments'));
        await tester.pumpAndSettle();

        expect(find.byType(AppointmentListScreen), findsOneWidget);
        expect(find.byType(BackButton), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(currentPath(router), '/');
      },
    );

    testWidgets(
      'pushing /decoder/behavior covers the shell + leaves a back arrow',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouter(tester);

        unawaited(router.push('/decoder/behavior'));
        await tester.pumpAndSettle();

        expect(find.byType(BehaviorPickerScreen), findsOneWidget);
        expect(find.byType(BackButton), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);

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
  final DateTime now = DateTime.utc(2026, 5, 30, 12);
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      authBackendProvider.overrideWithValue(auth),
      // Home tab depends on this; the wired router test never sets up
      // a drift store, so swap a synthetic conversation in.
      homeConversationProvider.overrideWith(
        (_) async => Conversation(
          id: 'wired-conv',
          title: 'Today',
          createdAt: now,
          updatedAt: now,
        ),
      ),
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

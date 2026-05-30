import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/auth_provider.dart';
import '../providers/onboarding_provider.dart';
import '../screens/chat/chat_screen.dart';
import '../screens/chat/conversation_list_screen.dart';
import '../screens/crisis/crisis_card_screen.dart';
import '../screens/decoder/behavior_picker_screen.dart';
import '../screens/decoder/decoder_result_screen.dart';
import '../screens/decoder/triage_screen.dart';
import '../screens/home_screen.dart';
import '../screens/journal/journal_entry_screen.dart';
import '../screens/journal/journal_screen.dart';
import '../screens/library/library_card_screen.dart';
import '../screens/library/library_screen.dart';
import '../screens/onboarding/sign_in_screen.dart';
import '../screens/onboarding/welcome_carousel.dart';
import '../screens/settings/settings_screen.dart';
import '../widgets/tab_scaffold.dart';

part 'router.g.dart';

/// Route names for go_router. Use these instead of raw path strings
/// when calling `context.goNamed(...)` so a rename only touches one
/// place.
class CareblazersRoutes {
  CareblazersRoutes._();

  static const String home = 'home';
  static const String journal = 'journal';
  static const String library = 'library';
  static const String crisis = 'crisis';
  static const String onboarding = 'onboarding';
  static const String signIn = 'sign-in';
  static const String settings = 'settings';
  static const String decoderBehavior = 'decoder-behavior';
  static const String decoderTriage = 'decoder-triage';
  static const String decoderResult = 'decoder-result';
  static const String journalEntry = 'journal-entry';
  static const String libraryCard = 'library-card';
  static const String chatList = 'chat-list';
  static const String chatThread = 'chat-thread';
}

/// Build a fresh GoRouter wired with every BUILD_SPEC.md §5 route.
///
/// Exposed as a builder (not a singleton) so tests get isolated router
/// instances and the demo tour can rebuild with different overrides.
///
/// [redirect] + [refreshListenable] are optional so widget tests that
/// only probe route registration (no auth/onboarding state) can still
/// construct a router with no gates. The production wiring lives in
/// [careblazersRouterProvider]; that's the path the running app uses.
GoRouter buildRouter({
  String initialLocation = '/',
  GoRouterRedirect? redirect,
  Listenable? refreshListenable,
}) {
  final GlobalKey<NavigatorState> rootNavigatorKey =
      GlobalKey<NavigatorState>();

  return GoRouter(
    initialLocation: initialLocation,
    navigatorKey: rootNavigatorKey,
    redirect: redirect,
    refreshListenable: refreshListenable,
    routes: <RouteBase>[
      // Top-level (pushed) routes — outside the tab shell. `parent
      // NavigatorKey: rootNavigatorKey` makes them push onto the root
      // navigator (above the shell) instead of onto a branch
      // navigator. Without that, pushing one of these from inside a
      // tab branch would silently fail to update the displayed
      // location. The pushed screen covers the bottom tab bar and
      // auto-renders a back arrow in the AppBar.
      GoRoute(
        path: '/onboarding',
        name: CareblazersRoutes.onboarding,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const WelcomeCarousel(),
      ),
      GoRoute(
        path: '/sign-in',
        name: CareblazersRoutes.signIn,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const SignInScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: CareblazersRoutes.settings,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const SettingsScreen(),
      ),
      GoRoute(
        path: '/decoder/behavior',
        name: CareblazersRoutes.decoderBehavior,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const BehaviorPickerScreen(),
      ),
      GoRoute(
        path: '/decoder/triage',
        name: CareblazersRoutes.decoderTriage,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) {
          // The behavior picker (BUILD_SPEC.md §5.2) pushes here with a
          // [TriageArgs] payload. A deep-link or accidental direct-nav
          // lands without args — render a soft fallback rather than
          // crashing the navigator stack.
          final Object? extra = state.extra;
          if (extra is! TriageArgs) {
            return Scaffold(
              appBar: AppBar(title: const Text('Triage')),
              body: const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Pick a behavior to get started.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          return TriageScreen(args: extra);
        },
      ),
      GoRoute(
        path: '/decoder/result',
        name: CareblazersRoutes.decoderResult,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) {
          // The triage screen (BUILD_SPEC.md §5.3) pushes here with a
          // [DecoderResultArgsExtra] in `state.extra`. A deep-link or
          // accidental direct-nav into `/decoder/result` lands without
          // args — render a soft fallback rather than crashing the
          // navigator stack.
          final Object? extra = state.extra;
          if (extra is! DecoderResultArgsExtra) {
            return Scaffold(
              appBar: AppBar(title: const Text('Decoder')),
              body: const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Pick a behavior and answer the three questions to '
                    'see the coaching script.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          return DecoderResultScreen(
            behavior: extra.behavior,
            triage: extra.triage,
            initialAttempt: extra.initialAttempt,
          );
        },
      ),
      GoRoute(
        path: '/journal/:id',
        name: CareblazersRoutes.journalEntry,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            JournalEntryScreen(entryId: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/library/:id',
        name: CareblazersRoutes.libraryCard,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            LibraryCardScreen(cardId: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/chat',
        name: CareblazersRoutes.chatList,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const ConversationListScreen(),
      ),
      GoRoute(
        path: '/chat/:id',
        name: CareblazersRoutes.chatThread,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) => ChatScreen(
          conversationId: state.pathParameters['id'] ?? '',
        ),
      ),

      // Tab shell — Home / Journal / Library / Crisis. Each branch is
      // a separate Navigator so back-stacks survive tab switches.
      StatefulShellRoute.indexedStack(
        builder: (
          BuildContext context,
          GoRouterState state,
          StatefulNavigationShell navigationShell,
        ) =>
            TabScaffold(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/',
                name: CareblazersRoutes.home,
                builder: (BuildContext context, GoRouterState state) =>
                    const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/journal',
                name: CareblazersRoutes.journal,
                builder: (BuildContext context, GoRouterState state) =>
                    const JournalScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/library',
                name: CareblazersRoutes.library,
                builder: (BuildContext context, GoRouterState state) =>
                    const LibraryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/crisis',
                name: CareblazersRoutes.crisis,
                builder: (BuildContext context, GoRouterState state) =>
                    const CrisisCardScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

/// Pure redirect policy — decoupled from go_router + riverpod so it's
/// unit-testable without pumping a widget tree (BUILD_SPEC.md §5.11 +
/// §5.12).
///
/// Two stacked gates, each returning the SAME path when already
/// satisfied so go_router treats the decision as stable and stops
/// re-evaluating (an unstable redirect would loop until go_router's
/// safety limit kicks in):
///
/// 1. **Onboarding gate** — until [onboardingCompleted] flips true,
///    every location collapses to `/onboarding`. The welcome carousel
///    itself returns null so the redirect doesn't ping-pong.
/// 2. **Auth gate** — onboarding complete but [authState] is
///    [AuthStateSignedOut] funnels every location to `/sign-in`. Sign-in
///    returns null for the same reason.
/// 3. Signed-in caregivers who land on `/onboarding` or `/sign-in`
///    (deep link, browser back) get bounced to `/` rather than being
///    asked to re-onboard.
String? careblazersRedirect({
  required String location,
  required bool onboardingCompleted,
  required AuthState authState,
}) {
  const String onboarding = '/onboarding';
  const String signIn = '/sign-in';
  const String home = '/';

  if (!onboardingCompleted) {
    return location == onboarding ? null : onboarding;
  }

  final bool signedIn = authState is AuthStateSignedIn;
  if (!signedIn) {
    return location == signIn ? null : signIn;
  }

  if (location == onboarding || location == signIn) {
    return home;
  }
  return null;
}

/// `ChangeNotifier` that bridges the riverpod auth-state stream + the
/// [onboardingCompletedProvider] notifier into a single [Listenable]
/// that go_router's `refreshListenable` understands.
///
/// Owned by [careblazersRouterProvider]; widget tests that wire the
/// redirect by hand can construct one directly and drive it with
/// [updateAuthState] + [notify].
@visibleForTesting
class AuthOnboardingRefresh extends ChangeNotifier {
  AuthState _authState = const AuthState.signedOut();

  /// Last [AuthState] the bridge observed. The redirect closure reads
  /// this synchronously instead of awaiting the stream on every
  /// evaluation — go_router calls `redirect` from a non-async path.
  AuthState get authState => _authState;

  /// Fed the auth stream's payload; updates [authState] + fires
  /// listeners so go_router re-evaluates the active redirect.
  void updateAuthState(AuthState next) {
    _authState = next;
    notifyListeners();
  }

  /// Fire listeners without changing [authState]. Used by the
  /// onboarding-complete listener — the redirect re-reads
  /// `onboardingCompletedProvider` from the ref on every evaluation, so
  /// the bridge only needs to wake go_router up.
  void notify() => notifyListeners();
}

/// Production GoRouter wiring — assembles [buildRouter] with the
/// auth + onboarding redirect (BUILD_SPEC.md §5.11 + §5.12) and the
/// [AuthOnboardingRefresh] listenable so the redirect re-runs on every
/// state transition.
///
/// `keepAlive: true` so the router survives across the rebuilds
/// `MaterialApp.router` triggers — without it, every theme/textScaler
/// change would tear the router (and its navigation stack) down.
@Riverpod(keepAlive: true)
GoRouter careblazersRouter(Ref ref) {
  final AuthOnboardingRefresh refresh = AuthOnboardingRefresh();

  // Onboarding flips a bool — the redirect re-reads the provider on
  // every evaluation, so all this listener has to do is wake go_router.
  ref.listen<bool>(
    onboardingCompletedProvider,
    (bool? _, bool __) => refresh.notify(),
  );

  // The auth state stream is the source of truth for the auth gate;
  // cache the latest payload on the bridge so the redirect closure can
  // read it synchronously.
  final AuthProvider auth = ref.read(authProvider);
  final StreamSubscription<AuthState> sub =
      auth.watchAuthState().listen(refresh.updateAuthState);

  ref.onDispose(() {
    sub.cancel();
    refresh.dispose();
  });

  return buildRouter(
    refreshListenable: refresh,
    redirect: (BuildContext context, GoRouterState state) =>
        careblazersRedirect(
      location: state.matchedLocation,
      onboardingCompleted: ref.read(onboardingCompletedProvider),
      authState: refresh.authState,
    ),
  );
}

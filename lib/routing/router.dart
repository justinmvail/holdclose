import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
}

/// Build a fresh GoRouter wired with every BUILD_SPEC.md §5 route.
///
/// Exposed as a builder (not a singleton) so tests get isolated router
/// instances and the demo tour can rebuild with different overrides.
GoRouter buildRouter({String initialLocation = '/'}) {
  final GlobalKey<NavigatorState> rootNavigatorKey =
      GlobalKey<NavigatorState>();

  return GoRouter(
    initialLocation: initialLocation,
    navigatorKey: rootNavigatorKey,
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
        builder: (BuildContext context, GoRouterState state) =>
            const TriageScreen(),
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


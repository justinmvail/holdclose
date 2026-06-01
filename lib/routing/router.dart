import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/auth_provider.dart';
import '../providers/onboarding_provider.dart';
import '../screens/chat/chat_screen.dart';
import '../screens/chat/conversation_list_screen.dart';
import '../models/forum.dart';
import '../screens/community/admin_reports_screen.dart';
import '../screens/community/community_feed_screen.dart';
import '../screens/community/community_guidelines_screen.dart';
import '../screens/community/post_compose_screen.dart';
import '../screens/community/post_detail_screen.dart';
import '../screens/crisis/crisis_card_screen.dart';
import '../screens/decoder/behavior_picker_screen.dart';
import '../screens/decoder/decoder_result_screen.dart';
import '../screens/decoder/triage_screen.dart';
import '../screens/home_screen.dart';
import '../screens/journal/journal_entry_screen.dart';
import '../screens/journal/journal_screen.dart';
import '../screens/journal/journal_wizard_screen.dart';
import '../screens/medical/health_log_entry_form.dart';
import '../screens/medical/health_log_screen.dart';
import '../screens/medical/medical_hub_screen.dart';
import '../screens/appointment/appointment_detail_screen.dart';
import '../screens/appointment/appointment_form_screen.dart';
import '../screens/appointment/appointment_list_screen.dart';
import '../screens/medication/dose_log_screen.dart';
import '../screens/medication/medication_form_screen.dart';
import '../screens/medication/medication_list_screen.dart';
import '../screens/onboarding/sign_in_screen.dart';
import '../screens/onboarding/welcome_carousel.dart';
import '../screens/settings/settings_screen.dart';
import '../services/voice_intake.dart';
import '../widgets/tab_scaffold.dart';

part 'router.g.dart';

/// Route names for go_router. Use these instead of raw path strings
/// when calling `context.goNamed(...)` so a rename only touches one
/// place.
class CareblazersRoutes {
  CareblazersRoutes._();

  static const String home = 'home';
  static const String journal = 'journal';
  static const String crisis = 'crisis';
  static const String onboarding = 'onboarding';
  static const String signIn = 'sign-in';
  static const String settings = 'settings';
  static const String decoderBehavior = 'decoder-behavior';
  static const String decoderTriage = 'decoder-triage';
  static const String decoderResult = 'decoder-result';
  static const String journalEntry = 'journal-entry';
  static const String journalNew = 'journal-new';
  static const String chatList = 'chat-list';
  static const String chatThread = 'chat-thread';
  static const String medicationList = 'medication-list';
  static const String medicationForm = 'medication-form';
  static const String medicationDoseLog = 'medication-dose-log';
  static const String appointmentList = 'appointment-list';
  static const String appointmentDetail = 'appointment-detail';
  static const String appointmentForm = 'appointment-form';
  static const String appointmentEdit = 'appointment-edit';
  static const String community = 'community';
  static const String communityPostDetail = 'community-post-detail';
  static const String communityCompose = 'community-compose';
  static const String communityGuidelines = 'community-guidelines';
  static const String communityAdminReports = 'community-admin-reports';

  // Phase 14 IA — Medical hub + its feature pages (BUILD_SPEC.md §4–§5).
  // The hub branch (`medicalHub` → `/medical`) lands in this phase as a
  // placeholder; the feature-page names below are forward-declared here
  // so Phases 14.15–14.24 can wire `goNamed(...)` without re-touching
  // this enum-like surface. Only `medicalHub` + `medicalCardsEmergency`
  // resolve to a registered route today; the rest gain routes as their
  // owning phase lands.
  static const String medicalHub = 'medical-hub';
  static const String medicalHealthLog = 'medical-health-log';
  static const String medicalHealthLogNew = 'medical-health-log-new';
  static const String medicalHealthLogEdit = 'medical-health-log-edit';
  static const String medicalCarePlan = 'medical-care-plan';
  static const String medicalSchedule = 'medical-schedule';
  static const String medicalCardsHub = 'medical-cards-hub';
  static const String medicalCardsEmergency = 'medical-cards-emergency';
  static const String medicalCardsPoa = 'medical-cards-poa';
  static const String medicalCardsIds = 'medical-cards-ids';

  // Phase 14 IA — Care Team hub + its feature pages. Same forward-
  // declaration contract as the Medical names: `teamHub` → `/team`
  // lands here as a placeholder, the rest gain routes in 14.26–14.33.
  static const String teamHub = 'team-hub';
  static const String teamCalendar = 'team-calendar';
  static const String teamTasks = 'team-tasks';
  static const String teamShifts = 'team-shifts';
  static const String teamCircle = 'team-circle';
  static const String teamCircleInvite = 'team-circle-invite';
  static const String teamActivity = 'team-activity';
  static const String teamExpenses = 'team-expenses';
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
      // Journal moved out of the tab bar in the Phase 14 IA refactor —
      // it's no longer a shell branch. The list + wizard + entry detail
      // are top-level pushed routes (root navigator) reached from Home's
      // quick actions and the Recent Activity card. `/journal/new` is
      // registered before `/journal/:id` so the literal `new` segment
      // isn't swallowed by the `:id` parameter.
      GoRoute(
        path: '/journal',
        name: CareblazersRoutes.journal,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const JournalScreen(),
      ),
      GoRoute(
        path: '/journal/new',
        name: CareblazersRoutes.journalNew,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) {
          // Two ways in: the chat coach pushes a fully-formed
          // [JournalWizardArgs]; the Home Add sheet's voice button
          // pushes an [AddSheetTranscript] (journal-entry or quick-note
          // kind). The voice-intake bridge (Phase 14.14) turns the
          // latter into the wizard's initial value; anything else opens
          // the wizard blank.
          final Object? extra = state.extra;
          JournalWizardArgs? args;
          if (extra is JournalWizardArgs) {
            args = extra;
          } else {
            final String? transcript = VoiceIntake.journalTranscript(extra);
            if (transcript != null) {
              args = JournalWizardArgs(initialTranscript: transcript);
            }
          }
          return JournalWizardScreen(args: args);
        },
      ),
      GoRoute(
        path: '/journal/:id',
        name: CareblazersRoutes.journalEntry,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            JournalEntryScreen(entryId: state.pathParameters['id'] ?? ''),
      ),
      // Medications + Appointments moved out of the tab bar in the Phase
      // 14 IA refactor — they live under the Medical hub now and are
      // reached as top-level pushed routes (root navigator) from Home's
      // medical cards + the Medical hub tiles (Phase 14.15+). The nested
      // form/detail routes already pushed onto the root navigator; the
      // only change here is the list root joining them at the top level.
      GoRoute(
        path: '/medications',
        name: CareblazersRoutes.medicationList,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const MedicationListScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            name: CareblazersRoutes.medicationForm,
            parentNavigatorKey: rootNavigatorKey,
            builder: (BuildContext context, GoRouterState state) =>
                const MedicationFormScreen(),
          ),
          GoRoute(
            path: 'today',
            name: CareblazersRoutes.medicationDoseLog,
            parentNavigatorKey: rootNavigatorKey,
            // The Home Add sheet's voice button may push a dose-kind
            // [AddSheetTranscript]; the voice-intake bridge (Phase
            // 14.14) pre-fills the dose-note field from it.
            builder: (BuildContext context, GoRouterState state) =>
                DoseLogScreen(initialNote: VoiceIntake.doseNote(state.extra)),
          ),
        ],
      ),
      GoRoute(
        path: '/appointments',
        name: CareblazersRoutes.appointmentList,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const AppointmentListScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            name: CareblazersRoutes.appointmentForm,
            parentNavigatorKey: rootNavigatorKey,
            // The Home Add sheet's voice button may push an
            // appointment-kind [AddSheetTranscript]; the voice-intake
            // bridge (Phase 14.14) pre-fills the visit-notes textarea.
            builder: (BuildContext context, GoRouterState state) =>
                AppointmentFormScreen(
              initialNotes: VoiceIntake.appointmentNotes(state.extra),
            ),
          ),
          GoRoute(
            path: ':id',
            name: CareblazersRoutes.appointmentDetail,
            parentNavigatorKey: rootNavigatorKey,
            builder: (BuildContext context, GoRouterState state) =>
                AppointmentDetailScreen(
              appointmentId: state.pathParameters['id'] ?? '',
            ),
            routes: <RouteBase>[
              GoRoute(
                path: 'edit',
                name: CareblazersRoutes.appointmentEdit,
                parentNavigatorKey: rootNavigatorKey,
                builder: (BuildContext context, GoRouterState state) =>
                    AppointmentFormScreen(
                  appointmentId: state.pathParameters['id'],
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/community/compose',
        name: CareblazersRoutes.communityCompose,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const PostComposeScreen(),
      ),
      GoRoute(
        path: '/community/guidelines',
        name: CareblazersRoutes.communityGuidelines,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const CommunityGuidelinesScreen(),
      ),
      GoRoute(
        path: '/community/admin/reports',
        name: CareblazersRoutes.communityAdminReports,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const AdminReportsScreen(),
      ),
      GoRoute(
        path: '/community/:postId',
        name: CareblazersRoutes.communityPostDetail,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) {
          // Feed tiles push here with the already-fetched [ForumPost]
          // as `extra` so the header renders immediately instead of
          // blanking while the post fetch lands. A deep-link with no
          // extra falls through to a fetch-by-id path.
          final Object? extra = state.extra;
          return PostDetailScreen(
            postId: state.pathParameters['postId'] ?? '',
            initialPost: extra is ForumPost ? extra : null,
          );
        },
      ),
      // Crisis card — deep-link compatibility shim (Phase 14.5). The
      // emergency content now lives at `/medical/cards/emergency` under
      // the Medical hub; `/crisis` survives only so old notification
      // deep links + saved shortcuts still resolve. It redirects to the
      // canonical location rather than rendering a screen of its own.
      // Phase 14.23 deletes the old CrisisCardScreen and lands the real
      // Emergency Card at the redirect target — this route stays alive.
      GoRoute(
        path: '/crisis',
        name: CareblazersRoutes.crisis,
        parentNavigatorKey: rootNavigatorKey,
        redirect: (BuildContext context, GoRouterState state) =>
            '/medical/cards/emergency',
      ),
      // Tab shell — the fixed 5-tab bar (Phase 14 IA refactor,
      // BUILD_SPEC.md §4.1): Home · Medical · Team · Chat · Community.
      // Always exactly five branches, always visible (the old
      // `useTrackers` visibility toggles are gone). Each branch is a
      // separate Navigator so back-stacks survive tab switches.
      //
      // Medical + Team are tile-hub landings (placeholders here until
      // Phase 14.15 / 14.26 land the real hubs); Chat + Community are
      // direct landings. Branch order MUST match
      // `TabScaffold.tabBranchPaths` index-for-index.
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
          // Medical hub (Phase 14.15). The emergency card is registered
          // as a pushed child now — it's the `/crisis` redirect target +
          // the Home pinned-card destination (Phase 14.8). Until Phase
          // 14.23 it renders the existing CrisisCardScreen; 14.23 swaps in
          // the real Emergency Card and deletes the old screen.
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/medical',
                name: CareblazersRoutes.medicalHub,
                builder: (BuildContext context, GoRouterState state) =>
                    const MedicalHubScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'cards/emergency',
                    name: CareblazersRoutes.medicalCardsEmergency,
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (BuildContext context, GoRouterState state) =>
                        const CrisisCardScreen(),
                  ),
                  // Health Log (Phase 14.17) — list + add/edit form.
                  // Pushed onto the root navigator so the feature pages
                  // cover the tab bar; `health-log/new` is registered
                  // before `health-log/:id/edit` so the literal `new`
                  // segment isn't swallowed by the `:id` parameter.
                  GoRoute(
                    path: 'health-log',
                    name: CareblazersRoutes.medicalHealthLog,
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (BuildContext context, GoRouterState state) =>
                        const HealthLogScreen(),
                    routes: <RouteBase>[
                      GoRoute(
                        path: 'new',
                        name: CareblazersRoutes.medicalHealthLogNew,
                        parentNavigatorKey: rootNavigatorKey,
                        builder: (BuildContext context, GoRouterState state) =>
                            const HealthLogEntryForm(),
                      ),
                      GoRoute(
                        path: ':id/edit',
                        name: CareblazersRoutes.medicalHealthLogEdit,
                        parentNavigatorKey: rootNavigatorKey,
                        builder: (BuildContext context, GoRouterState state) =>
                            HealthLogEntryForm(
                          entryId: state.pathParameters['id'],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          // Care Team hub (Phase 14.26 replaces this placeholder with
          // CareTeamHubScreen).
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/team',
                name: CareblazersRoutes.teamHub,
                builder: (BuildContext context, GoRouterState state) =>
                    Scaffold(appBar: AppBar(title: const Text('Care Team'))),
              ),
            ],
          ),
          // Chat — direct landing. `/chat/:id` pushes onto THIS branch's
          // navigator (no `parentNavigatorKey`), so a thread keeps the
          // tab bar and pops back to the conversation list.
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/chat',
                name: CareblazersRoutes.chatList,
                builder: (BuildContext context, GoRouterState state) =>
                    const ConversationListScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: ':id',
                    name: CareblazersRoutes.chatThread,
                    builder: (BuildContext context, GoRouterState state) =>
                        ChatScreen(
                      conversationId: state.pathParameters['id'] ?? '',
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Community — direct landing (Feed; Learn/Support sub-nav
          // arrives in Phase 14.36).
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/community',
                name: CareblazersRoutes.community,
                builder: (BuildContext context, GoRouterState state) =>
                    const CommunityFeedScreen(),
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

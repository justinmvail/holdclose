import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/auth_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/patient_configured_provider.dart';
import '../screens/chat/chat_screen.dart';
import '../screens/chat/conversation_list_screen.dart';
import '../models/forum.dart';
import '../screens/community/admin_reports_screen.dart';
import '../screens/community/community_feed_screen.dart';
import '../screens/community/community_guidelines_screen.dart';
import '../screens/community/learn_playbook_detail_screen.dart';
import '../screens/community/post_compose_screen.dart';
import '../screens/community/post_detail_screen.dart';
import '../screens/decoder/behavior_picker_screen.dart';
import '../screens/decoder/decoder_result_screen.dart';
import '../screens/decoder/triage_screen.dart';
import '../screens/home_screen.dart';
import '../screens/journal/journal_entry_screen.dart';
import '../screens/journal/journal_screen.dart';
import '../screens/journal/journal_wizard_screen.dart';
import '../screens/medical/care_plan_routine_form.dart';
import '../screens/medical/care_plan_routines_screen.dart';
import '../screens/medical/emergency_card_edit_screen.dart';
import '../screens/medical/emergency_card_screen.dart';
import '../screens/medical/health_log_entry_form.dart';
import '../screens/medical/health_log_screen.dart';
import '../screens/medical/medical_hub_screen.dart';
import '../screens/appointment/appointment_detail_screen.dart';
import '../screens/appointment/appointment_form_screen.dart';
import '../screens/appointment/appointment_list_screen.dart';
import '../screens/medication/dose_log_screen.dart';
import '../screens/medication/dose_window_list_screen.dart';
import '../screens/medication/medication_form_screen.dart';
import '../screens/medication/medication_list_screen.dart';
import '../screens/onboarding/loved_one_setup_screen.dart';
import '../screens/onboarding/sign_in_screen.dart';
import '../screens/onboarding/welcome_carousel.dart';
import '../screens/settings/loved_ones_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/team/activity_screen.dart';
import '../screens/team/calendar_screen.dart';
import '../screens/team/care_circle_screen.dart';
import '../screens/team/care_team_hub_screen.dart';
import '../screens/team/circle_qr_screen.dart';
import '../screens/team/circle_scan_screen.dart';
import '../screens/team/username_screen.dart';
import '../screens/team/expenses_screen.dart';
import '../screens/team/shifts_screen.dart';
import '../screens/team/tasks_screen.dart';
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
  static const String setup = 'setup';
  static const String settings = 'settings';
  // Multi-patient "Loved ones" manager (Issue #6). `lovedOnes` → the
  // switcher/manager; `lovedOnesAdd` → the setup wizard reused in add
  // mode to append + activate another loved one.
  static const String lovedOnes = 'loved-ones';
  static const String lovedOnesAdd = 'loved-ones-add';
  static const String decoderBehavior = 'decoder-behavior';
  static const String decoderTriage = 'decoder-triage';
  static const String decoderResult = 'decoder-result';
  static const String journalEntry = 'journal-entry';
  static const String journalNew = 'journal-new';
  static const String chatList = 'chat-list';
  static const String chatThread = 'chat-thread';
  static const String medicationList = 'medication-list';
  static const String medicationForm = 'medication-form';
  static const String medicationEdit = 'medication-edit';
  static const String medicationDoseLog = 'medication-dose-log';
  static const String medicationWindowList = 'medication-window-list';
  static const String medicationWindowNew = 'medication-window-new';
  static const String medicationWindowEdit = 'medication-window-edit';
  static const String appointmentList = 'appointment-list';
  static const String appointmentDetail = 'appointment-detail';
  static const String appointmentForm = 'appointment-form';
  static const String appointmentEdit = 'appointment-edit';
  static const String community = 'community';
  static const String communityPostDetail = 'community-post-detail';
  static const String communityPostEdit = 'community-post-edit';
  static const String communityCompose = 'community-compose';
  static const String communityGuidelines = 'community-guidelines';
  static const String communityAdminReports = 'community-admin-reports';
  // Community → Learn playbook detail (Phase 14.37). Pushed onto the root
  // navigator so it covers the tab bar, matching the post-detail page.
  // (Videos deep-link to YouTube and have no in-app route;
  // fb_1780932492880889.)
  static const String communityLearnPlaybook = 'community-learn-playbook';

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
  static const String medicalRoutines = 'medical-routines';
  static const String medicalRoutineNew = 'medical-routine-new';
  static const String medicalRoutineEdit = 'medical-routine-edit';
  static const String medicalCardsEmergency = 'medical-cards-emergency';
  static const String medicalCardsEmergencyEdit =
      'medical-cards-emergency-edit';

  // Phase 14 IA — Care Team hub + its feature pages. Same forward-
  // declaration contract as the Medical names: `teamHub` → `/team`
  // lands here as a placeholder, the rest gain routes in 14.26–14.33.
  static const String teamHub = 'team-hub';
  static const String teamCalendar = 'team-calendar';
  static const String teamTasks = 'team-tasks';
  static const String teamShifts = 'team-shifts';
  static const String teamCircle = 'team-circle';
  // Care-circle connect (2026-06-06) — username onboarding + QR connect.
  static const String teamCircleUsername = 'team-circle-username';
  static const String teamCircleQr = 'team-circle-qr';
  static const String teamCircleScan = 'team-circle-scan';
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
      // New-user loved-one setup wizard — the third gate after the
      // welcome carousel + sign-in. An authenticated caregiver with no
      // [Patient] on file is funnelled here (see `careblazersRedirect`)
      // to create "their person"; on save it lands them on Home. A pushed
      // root-navigator route like the other pre-tab screens, so it covers
      // the tab shell and relies on its own in-page chrome (no OS back).
      GoRoute(
        path: '/setup',
        name: CareblazersRoutes.setup,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const LovedOneSetupScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: CareblazersRoutes.settings,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const SettingsScreen(),
      ),
      // Multi-patient "Loved ones" manager (Issue #6) — reached from
      // Settings → "Loved ones". The `add` child reuses the onboarding
      // [LovedOneSetupScreen] in add mode, so a new loved one is appended
      // + made active rather than gating the first-run flow. Both push
      // onto the root navigator so they cover the tab bar like Settings.
      GoRoute(
        path: '/loved-ones',
        name: CareblazersRoutes.lovedOnes,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const LovedOnesScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'add',
            name: CareblazersRoutes.lovedOnesAdd,
            parentNavigatorKey: rootNavigatorKey,
            builder: (BuildContext context, GoRouterState state) =>
                const LovedOneSetupScreen(isAdd: true),
          ),
        ],
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
      // Community → Learn playbook detail (Phase 14.37). The Learn segment
      // lives in-tab under `/community`; this pushed page renders the
      // seeded playbook content. Registered before the `/community/:postId`
      // catch-all so the static `learn` segment is never swallowed by the
      // post-detail param route. (Videos no longer have an in-app detail
      // screen — cards deep-link straight to YouTube; fb_1780932492880889.)
      GoRoute(
        path: '/community/learn/playbooks/:id',
        name: CareblazersRoutes.communityLearnPlaybook,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            LearnPlaybookDetailScreen(
          playbookId: state.pathParameters['id'] ?? '',
        ),
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
        routes: <RouteBase>[
          // Edit one of the caregiver's OWN posts — the compose surface in
          // edit mode, prefilled from the post and PATCHing the body on save.
          // Pushed onto the root navigator so it covers the tab bar like the
          // detail page it launches from; the owner-only entry point lives in
          // the post header overflow menu (gated on profile ownership). The
          // post rides along as `extra` so the form prefills without a
          // fetch-by-id round-trip.
          GoRoute(
            path: 'edit',
            name: CareblazersRoutes.communityPostEdit,
            parentNavigatorKey: rootNavigatorKey,
            builder: (BuildContext context, GoRouterState state) {
              final Object? extra = state.extra;
              return PostComposeScreen(
                editPost: extra is ForumPost ? extra : null,
              );
            },
          ),
        ],
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
      // Tab shell — the fixed 4-tab bar (IA refactor 2026-06-06):
      // Home · Care · Chat · Community. Always exactly four branches,
      // always visible. Each branch is a separate Navigator so
      // back-stacks survive tab switches.
      //
      // The former "Medical" tab is now "Care" (its branch path stays
      // `/medical` internally). The former "Team" tab was folded into
      // the Care branch — its `/team/*` routes now live alongside
      // `/medical` in the same branch. Care is a tile-hub landing; Chat
      // + Community are direct landings. Branch order MUST match
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
          // Care branch (Phase 14.15; renamed from Medical 2026-06-06).
          // The Care hub at `/medical` plus EVERY feature page a hub tile
          // opens. Caroline's alpha feedback (2026-06-07): the bottom tab
          // bar must stay visible after entering a Care tile — so the
          // tile landing pages and the sub-pages below them live INSIDE
          // this shell branch (no `parentNavigatorKey: rootNavigatorKey`)
          // and render in the branch navigator, keeping the bar. The
          // Medications / Appointments / Journal lists (reached from Home
          // too) moved in here as branch-level routes so their tiles keep
          // the bar as well; navigating to them from another tab simply
          // activates the Care tab. The PathHeader's parent crumb still
          // does `context.go('/medical')` to return to the hub.
          //
          // Genuinely full-screen surfaces stay on the root navigator
          // (covering the bar on purpose): the Care Circle connect flow
          // (username / QR / scan) reads as a focused modal task.
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/medical',
                name: CareblazersRoutes.medicalHub,
                builder: (BuildContext context, GoRouterState state) =>
                    const MedicalHubScreen(),
                routes: <RouteBase>[
                  // Emergency Card — the read-only ICE card first
                  // responders see. Renders in the Care branch so the tab
                  // bar stays; it's also the `/crisis` redirect target.
                  GoRoute(
                    path: 'cards/emergency',
                    name: CareblazersRoutes.medicalCardsEmergency,
                    builder: (BuildContext context, GoRouterState state) =>
                        const EmergencyCardScreen(),
                    routes: <RouteBase>[
                      // Edit form for the emergency card — conditions,
                      // medications, allergies, contacts, insurance, and
                      // donor status, saved through the EmergencyCards
                      // notifier. On the modern PathHeader pattern.
                      GoRoute(
                        path: 'edit',
                        name: CareblazersRoutes.medicalCardsEmergencyEdit,
                        builder: (BuildContext context, GoRouterState state) =>
                            const EmergencyCardEditScreen(),
                      ),
                    ],
                  ),
                  // Health Log (Phase 14.17) — list + add/edit form.
                  // `health-log/new` is registered before
                  // `health-log/:id/edit` so the literal `new` segment
                  // isn't swallowed by the `:id` parameter.
                  GoRoute(
                    path: 'health-log',
                    name: CareblazersRoutes.medicalHealthLog,
                    builder: (BuildContext context, GoRouterState state) =>
                        const HealthLogScreen(),
                    routes: <RouteBase>[
                      GoRoute(
                        path: 'new',
                        name: CareblazersRoutes.medicalHealthLogNew,
                        builder: (BuildContext context, GoRouterState state) =>
                            const HealthLogEntryForm(),
                      ),
                      GoRoute(
                        path: ':id/edit',
                        name: CareblazersRoutes.medicalHealthLogEdit,
                        builder: (BuildContext context, GoRouterState state) =>
                            HealthLogEntryForm(
                          entryId: state.pathParameters['id'],
                        ),
                      ),
                    ],
                  ),
                  // Routines (v2 Care Plan — BUILD_SPEC.md §5.13). The v1
                  // slot/stage CarePlanScreen + CarePlanSectionForm were
                  // deleted in favour of scheduled tasks projecting into
                  // the unified patient timeline. `routines/new` is
                  // registered before `routines/:id` so the literal `new`
                  // segment isn't swallowed by the `:id` parameter.
                  GoRoute(
                    path: 'routines',
                    name: CareblazersRoutes.medicalRoutines,
                    builder: (BuildContext context, GoRouterState state) =>
                        const CarePlanRoutinesScreen(),
                    routes: <RouteBase>[
                      GoRoute(
                        path: 'new',
                        name: CareblazersRoutes.medicalRoutineNew,
                        builder: (BuildContext context, GoRouterState state) =>
                            const CarePlanRoutineForm(),
                      ),
                      GoRoute(
                        path: ':id',
                        name: CareblazersRoutes.medicalRoutineEdit,
                        builder: (BuildContext context, GoRouterState state) =>
                            CarePlanRoutineForm(
                          routineId: state.pathParameters['id'],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              // Medications — the Care hub's "Medications" tile + Home's
              // dose-log shortcut. In the Care branch so the tab bar stays.
              GoRoute(
                path: '/medications',
                name: CareblazersRoutes.medicationList,
                builder: (BuildContext context, GoRouterState state) =>
                    const MedicationListScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'new',
                    name: CareblazersRoutes.medicationForm,
                    builder: (BuildContext context, GoRouterState state) =>
                        const MedicationFormScreen(),
                  ),
                  GoRoute(
                    path: 'today',
                    name: CareblazersRoutes.medicationDoseLog,
                    // The Home Add sheet's voice button may push a dose-kind
                    // [AddSheetTranscript]; the voice-intake bridge (Phase
                    // 14.14) pre-fills the dose-note field from it.
                    builder: (BuildContext context, GoRouterState state) =>
                        DoseLogScreen(initialNote: VoiceIntake.doseNote(state.extra)),
                  ),
                  // Edit a medication, pre-filled from its saved row (Phase
                  // 15.6). `:id/edit` is a two-segment path so it never
                  // shadows the literal `new` / `today` children above.
                  GoRoute(
                    path: ':id/edit',
                    name: CareblazersRoutes.medicationEdit,
                    builder: (BuildContext context, GoRouterState state) =>
                        MedicationFormScreen(
                      medicationId: state.pathParameters['id'],
                    ),
                  ),
                  // Dose-window management (v14 windows pivot). The list
                  // lives under /medications so the back stack reads
                  // Care › Medications › Windows; the form pushes on top of
                  // the list for add + edit.
                  GoRoute(
                    path: 'windows',
                    name: CareblazersRoutes.medicationWindowList,
                    builder: (BuildContext context, GoRouterState state) =>
                        const DoseWindowListScreen(),
                    routes: <RouteBase>[
                      GoRoute(
                        path: 'new',
                        name: CareblazersRoutes.medicationWindowNew,
                        builder: (BuildContext context, GoRouterState state) =>
                            const DoseWindowFormScreen(),
                      ),
                      GoRoute(
                        path: ':id',
                        name: CareblazersRoutes.medicationWindowEdit,
                        builder: (BuildContext context, GoRouterState state) =>
                            DoseWindowFormScreen(
                          windowId: state.pathParameters['id'],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              // Appointments — the Care hub's "Appointments" tile. In the
              // Care branch so the tab bar stays.
              GoRoute(
                path: '/appointments',
                name: CareblazersRoutes.appointmentList,
                builder: (BuildContext context, GoRouterState state) =>
                    const AppointmentListScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'new',
                    name: CareblazersRoutes.appointmentForm,
                    // The Home Add sheet's voice button may push an
                    // appointment-kind [AddSheetTranscript]; the voice-intake
                    // bridge (Phase 14.14) pre-fills the visit-notes textarea.
                    builder: (BuildContext context, GoRouterState state) =>
                        AppointmentFormScreen(
                      initialNotes: VoiceIntake.appointmentNotes(state.extra),
                      // The Schedule calendar's "Add" affordance passes the
                      // selected day as `?date=YYYY-MM-DD` so the new
                      // appointment lands on the day the caregiver viewed.
                      initialDate: _calendarDateParam(
                          state.uri.queryParameters['date']),
                    ),
                  ),
                  GoRoute(
                    path: ':id',
                    name: CareblazersRoutes.appointmentDetail,
                    builder: (BuildContext context, GoRouterState state) =>
                        AppointmentDetailScreen(
                      appointmentId: state.pathParameters['id'] ?? '',
                    ),
                    routes: <RouteBase>[
                      GoRoute(
                        path: 'edit',
                        name: CareblazersRoutes.appointmentEdit,
                        builder: (BuildContext context, GoRouterState state) =>
                            AppointmentFormScreen(
                          appointmentId: state.pathParameters['id'],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              // Journal — the Care hub's "Journal" tile + Home quick
              // actions + the decoder flow. In the Care branch so the tile
              // keeps the tab bar; reaching it from Home/decoder activates
              // the Care tab. `/journal/new` is registered before
              // `/journal/:id` so the literal `new` segment isn't swallowed
              // by the `:id` parameter.
              GoRoute(
                path: '/journal',
                name: CareblazersRoutes.journal,
                builder: (BuildContext context, GoRouterState state) =>
                    const JournalScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'new',
                    name: CareblazersRoutes.journalNew,
                    builder: (BuildContext context, GoRouterState state) {
                      // Two ways in: the chat coach pushes a fully-formed
                      // [JournalWizardArgs]; the Home Add sheet's voice
                      // button pushes an [AddSheetTranscript] (journal-entry
                      // or quick-note kind). The voice-intake bridge (Phase
                      // 14.14) turns the latter into the wizard's initial
                      // value; anything else opens the wizard blank.
                      final Object? extra = state.extra;
                      JournalWizardArgs? args;
                      if (extra is JournalWizardArgs) {
                        args = extra;
                      } else {
                        final String? transcript =
                            VoiceIntake.journalTranscript(extra);
                        if (transcript != null) {
                          args =
                              JournalWizardArgs(initialTranscript: transcript);
                        }
                      }
                      return JournalWizardScreen(args: args);
                    },
                  ),
                  GoRoute(
                    path: ':id',
                    name: CareblazersRoutes.journalEntry,
                    builder: (BuildContext context, GoRouterState state) =>
                        JournalEntryScreen(
                            entryId: state.pathParameters['id'] ?? ''),
                  ),
                ],
              ),
              // Care Circle coordination — folded into Care (2026-06-06):
              // the former Team tab's hub + feature pages live in the Care
              // branch's navigator (no separate tab). Their paths stay
              // `/team/*` internally so existing deep links keep resolving.
              GoRoute(
                path: '/team',
                name: CareblazersRoutes.teamHub,
                builder: (BuildContext context, GoRouterState state) =>
                    const CareTeamHubScreen(),
                routes: <RouteBase>[
                  // Shared Calendar (Phase 14.29) — the 7-day week view of
                  // appointments, tasks, shifts, and notes. In the Care
                  // branch so the tab bar stays (it's also the Care hub's
                  // "Schedule" tile via `?from=medical`).
                  GoRoute(
                    path: 'calendar',
                    name: CareblazersRoutes.teamCalendar,
                    // `?from=medical` (the Medical hub's "Schedule" tile)
                    // flips the path header to the Medical breadcrumb;
                    // `?date=YYYY-MM-DD` (the chat coach's "take me to that
                    // day" navigation) opens the calendar on that day.
                    builder: (BuildContext context, GoRouterState state) =>
                        CalendarScreen(
                      fromMedical:
                          state.uri.queryParameters['from'] == 'medical',
                      initialDate: _calendarDateParam(
                          state.uri.queryParameters['date']),
                    ),
                  ),
                  // Tasks board (Phase 14.30) — Open / Claimed / Done
                  // segmented task list. In the Care branch so the tab bar
                  // stays.
                  GoRoute(
                    path: 'tasks',
                    name: CareblazersRoutes.teamTasks,
                    builder: (BuildContext context, GoRouterState state) =>
                        const TasksScreen(),
                  ),
                  // Shifts board (Phase 14.31) — a 7-day coverage strip with
                  // per-caregiver bands + gap flags. In the Care branch so
                  // the tab bar stays.
                  GoRoute(
                    path: 'shifts',
                    name: CareblazersRoutes.teamShifts,
                    builder: (BuildContext context, GoRouterState state) =>
                        const ShiftsScreen(),
                  ),
                  // Activity feed (Phase 14.32) — the chronological,
                  // filterable feed of every care event. In the Care branch
                  // so the tab bar stays.
                  GoRoute(
                    path: 'activity',
                    name: CareblazersRoutes.teamActivity,
                    builder: (BuildContext context, GoRouterState state) =>
                        const ActivityScreen(),
                  ),
                  // Expenses ledger (Phase 14.33) — shared costs grouped by
                  // month with a sticky current-month total. In the Care
                  // branch so the tab bar stays.
                  GoRoute(
                    path: 'expenses',
                    name: CareblazersRoutes.teamExpenses,
                    builder: (BuildContext context, GoRouterState state) =>
                        const ExpensesScreen(),
                  ),
                  // Care Circle roster (Phase 14.27). In the Care branch so
                  // the tab bar stays; the connect flow below (username / QR
                  // / scan) stays full-screen on the root navigator as a
                  // focused modal task.
                  GoRoute(
                    path: 'circle',
                    name: CareblazersRoutes.teamCircle,
                    builder: (BuildContext context, GoRouterState state) =>
                        const CareCircleScreen(),
                    routes: <RouteBase>[
                      // Care-circle connect (2026-06-06) — pick an
                      // @username, show your invite QR, scan another
                      // caregiver's QR to join their circle. These stay on
                      // the root navigator (full-screen) — they're a focused
                      // modal connect task, not a browsable hub page.
                      GoRoute(
                        path: 'username',
                        name: CareblazersRoutes.teamCircleUsername,
                        parentNavigatorKey: rootNavigatorKey,
                        builder: (BuildContext context, GoRouterState state) =>
                            const UsernameScreen(),
                      ),
                      GoRoute(
                        path: 'qr',
                        name: CareblazersRoutes.teamCircleQr,
                        parentNavigatorKey: rootNavigatorKey,
                        builder: (BuildContext context, GoRouterState state) =>
                            const CircleQrScreen(),
                      ),
                      GoRoute(
                        path: 'scan',
                        name: CareblazersRoutes.teamCircleScan,
                        parentNavigatorKey: rootNavigatorKey,
                        builder: (BuildContext context, GoRouterState state) =>
                            const CircleScanScreen(),
                      ),
                    ],
                  ),
                ],
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
                    builder: (BuildContext context, GoRouterState state) {
                      final String id = state.pathParameters['id'] ?? '';
                      // Key by conversation id so navigating thread→thread
                      // (e.g. the center mic opening a fresh thread while
                      // already viewing one) gives a NEW ChatScreen State
                      // that loads the right messages — without a key the
                      // route reuses the prior screen and shows the wrong
                      // conversation (fb_1781035154885086).
                      return ChatScreen(
                        key: ValueKey<String>('chat-$id'),
                        conversationId: id,
                      );
                    },
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
/// 3. **Loved-one setup gate** — onboarded + signed-in but no [Patient]
///    on file yet ([patientConfigured] false) funnels every location to
///    `/setup` so the caregiver creates "their person" before reaching
///    the app. The wizard itself returns null so the redirect doesn't
///    ping-pong; in `DEMO_MODE` the seeded Mary keeps this flag true so
///    the wizard is skipped entirely.
/// 4. Signed-in caregivers who land on `/onboarding` or `/sign-in`
///    (deep link, browser back) get bounced to `/` rather than being
///    asked to re-onboard.
String? careblazersRedirect({
  required String location,
  required bool onboardingCompleted,
  required AuthState authState,
  required bool patientConfigured,
}) {
  const String onboarding = '/onboarding';
  const String signIn = '/sign-in';
  const String setup = '/setup';
  const String home = '/';

  if (!onboardingCompleted) {
    return location == onboarding ? null : onboarding;
  }

  final bool signedIn = authState is AuthStateSignedIn;
  if (!signedIn) {
    return location == signIn ? null : signIn;
  }

  if (!patientConfigured) {
    return location == setup ? null : setup;
  }

  if (location == onboarding || location == signIn || location == setup) {
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

  // The loved-one setup gate flips a bool too: false until the
  // persisted patient resolves (or the wizard saves one + calls
  // `reload`), true once "their person" is on file. Same deal — the
  // redirect re-reads the provider on every evaluation, so the listener
  // just wakes go_router when the value lands.
  ref.listen<bool>(
    patientConfiguredProvider,
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
      patientConfigured: ref.read(patientConfiguredProvider),
    ),
  );
}

/// Parse the calendar route's `?date=YYYY-MM-DD` query param into the day
/// the screen should open on, or null when absent/unparseable (then the
/// calendar defaults to today).
DateTime? _calendarDateParam(String? raw) =>
    (raw == null || raw.isEmpty) ? null : DateTime.tryParse(raw);

import 'package:holdclose/app.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/models/forum.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/documents_provider.dart';
import 'package:holdclose/providers/expenses_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/home_clock_provider.dart';
import 'package:holdclose/providers/llm_provider.dart';
import 'package:holdclose/providers/settings_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/tts_provider.dart';
import 'package:holdclose/routing/router.dart';
import 'package:holdclose/screens/chat/chat_screen.dart';
import 'package:holdclose/screens/chat/conversation_list_screen.dart';
import 'package:holdclose/screens/community/community_feed_screen.dart';
import 'package:holdclose/screens/home_screen.dart';
import 'package:holdclose/screens/medical/care_plan_routines_screen.dart';
import 'package:holdclose/screens/medical/emergency_card_screen.dart';
import 'package:holdclose/screens/medical/health_log_entry_form.dart';
import 'package:holdclose/screens/medical/health_log_screen.dart';
import 'package:holdclose/screens/medical/medical_hub_screen.dart';
import 'package:holdclose/screens/medication/dose_log_screen.dart';
import 'package:holdclose/screens/onboarding/sign_in_screen.dart';
import 'package:holdclose/screens/onboarding/welcome_carousel.dart';
import 'package:holdclose/screens/settings/settings_screen.dart';
import 'package:holdclose/screens/team/care_circle_screen.dart';
import 'package:holdclose/screens/team/care_team_hub_screen.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/chat_service.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:holdclose/services/seed_repository.dart';
import 'package:holdclose/widgets/home/schedule_card.dart';
import 'package:holdclose/widgets/path_header.dart';
import 'package:holdclose/widgets/tab_scaffold.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pinned wall clock for the whole tour — 11:00 AM, Mon Jun 1 2026.
///
/// Every clock-reading provider (home greeting, dose-log "now", community
/// relative timestamps) is overridden onto this so the captured demo
/// screenshots stay pixel-deterministic across runs regardless of when
/// the operator records the walkthrough.
DateTime _fixedNow() => DateTime(2026, 6, 1, 11, 0);

/// Scripted pitch walkthrough for the FOUR-tab information architecture
/// (IA refactor 2026-06-06; BUILD_SPEC.md §10.1, docs/MENU_LAYOUT_SPEC.md).
///
/// The bottom bar is the custom [TabScaffoldBar] — `Home · Care · Chat ·
/// Community` around the inline center mic; there is NO Material
/// [NavigationBar] anymore, so every tab tap here goes through the bar
/// widget (mirroring `tabFor()` in test/integration/test_harness.dart).
/// The old "Medical" tab is now the **Care** hub (route still `/medical`)
/// and the old "Team" tab lives under Care as the gated **Care Circle**
/// hub (routes still `/team/*`).
///
/// The tour IS the test: each leg pairs a `tester.tap()` with at least one
/// `expect(...)`, so a regression on any screen surfaces as a hard test
/// failure rather than a silent pass-through. End to end it drives:
/// Home dashboard → Settings (via the header profile icon) → a Schedule
/// dose group → dose log → the **Care** hub (Health Log add → Routines →
/// Emergency Card) → the **Care Circle** hub under Care (People roster +
/// connect actions) → **Chat** (open a seeded thread, send a message, and
/// get the canned demo coach's reply back) → **Community** (Feed → Learn →
/// Support → Feed) — capturing a demo screenshot on every hub/tab landing.
/// Screenshot labels `02_care` / `03_care-circle` supersede the stale
/// `02_medical` / `03_team` baselines from the five-tab era.
///
/// Pre-conditions per §10.1:
///   * `DEMO_MODE=true` build define set (gates [FakeAuthProvider] + the
///     sign-in screen's "Skip — explore as Mary's caregiver" CTA).
///   * `FakeLLMProvider` for deterministic coaching copy and
///     [DemoChatBackend] for deterministic chat replies — the DEMO_MODE
///     pitch build (and any `flutter test` run) already selects both via
///     the fake-engine rule; they're overridden defensively here so a
///     build that flipped `USE_FAKE_LLM=false` still runs canned.
///   * [InMemoryStorageProvider] pre-seeded with Mary Henderson + the demo
///     journal so the dashboard + Emergency Card land populated.
///   * A single in-memory [HoldcloseDatabase] backs every drift
///     repository (medications, chat, care circle, health log, …) so no
///     screen tries to open the on-device SQLite file under the test host.
///   * [NoopTTSProvider] so any PLAY tap doesn't spin up the `flutter_tts`
///     platform channel on the test host.
///
/// Run it (and regenerate the screenshot baselines) as:
///
///     flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true
///     flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true --update-goldens
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'demo tour — four-tab IA walkthrough: Home · Care · Chat · Community '
    '(BUILD_SPEC.md §10.1)',
    (WidgetTester tester) async {
      if (!demoModeEnabled) {
        fail(
          'demo_tour.dart requires --dart-define=DEMO_MODE=true so '
          'FakeAuthProvider + the sign-in demo-skip button are active.',
        );
      }

      // A fixed phone-ish surface so the captured screenshots are stable
      // and tall enough that the dashboard + feature pages render without
      // scroll-gating the tap targets the tour reaches for.
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Mary + the demo journal land in the storage backend (the
      // dashboard + Emergency Card read the loved one from here).
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      await SeedRepository(storage: storage).populateAll();

      // One in-memory drift DB backs every repository the IA touches, so
      // each Care / Care Circle / Chat screen builds against a coherent
      // store instead of trying to open the on-device SQLite file.
      final HoldcloseDatabase db =
          HoldcloseDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // Seed the medication tracker so the Home Schedule card — and the
      // dose log its Morning group taps through to — render a real dose.
      final MedicationRepository medRepo =
          MedicationRepository(db, clock: _fixedNow);
      await medRepo.upsertMedication(const Medication(
        id: 'med-don',
        name: 'Donepezil',
        dosage: '10 mg',
        route: MedicationRoute.oral,
      ));
      // v14 windows pivot — link Donepezil to a Morning window so the
      // 8 AM dose still appears on the Home Schedule card.
      await medRepo.upsertWindow(const DoseWindow(
        id: 'window-demo-patient-mary-morning',
        patientId: 'demo-patient-mary',
        label: 'Morning',
        anchorTime: TimeOfDay(hour: 8, minute: 0),
        sortOrder: 0,
      ));
      await medRepo.upsertEntry(MedicationWindowEntry(
        id: 'entry-don-morning',
        medicationId: 'med-don',
        windowId: 'window-demo-patient-mary-morning',
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));

      // Seed two chat threads so the conversation list has a "first
      // thread" to open. Ordering is most-recently-updated first, so the
      // sundowning thread (newest) sits at the top of the list.
      final ChatRepository chatRepo = ChatRepository(db);
      await _seedThread(
        chatRepo,
        id: 'convo-mother',
        createdAt: _fixedNow().subtract(const Duration(hours: 5)),
        userText:
            'What do I say when she asks for her mother who passed years ago?',
        assistantText:
            'Step into her reality — comfort the feeling, not the fact.',
      );
      await _seedThread(
        chatRepo,
        id: 'convo-sundowning',
        createdAt: _fixedNow().subtract(const Duration(hours: 1)),
        userText: 'Sundowning is hitting hard this week. What can I do?',
        assistantText:
            'Dim the lights early and keep the evening predictable — the '
            'brain is mid-transition, not misbehaving.',
      );

      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageBackendProvider.overrideWithValue(storage),
          llmProvider.overrideWithValue(const FakeLLMProvider()),
          // Chat rides the same deterministic rail: DEMO_MODE builds set
          // USE_FAKE_LLM=true (and `flutter test` implies it), which
          // already selects [DemoChatBackend] — this pins the same impl
          // against a stray define so the tour never reaches for the shim.
          chatLLMBackendProvider.overrideWithValue(const DemoChatBackend()),
          ttsProvider.overrideWith((Ref ref) => const NoopTTSProvider()),
          // Mirror main.dart: pipe SettingsNotifier through the TTS
          // settings selector so the muting state tracks the live
          // settings without per-screen plumbing.
          ttsSettingsProvider
              .overrideWith((Ref ref) => ref.watch(settingsProvider)),
          // Pin every wall clock so the screenshots stay deterministic.
          homeClockProvider.overrideWithValue(_fixedNow),
          doseLogClockProvider.overrideWithValue(_fixedNow),
          communityFeedClockProvider.overrideWithValue(_fixedNow),
          // Every drift repository points at the one shared in-memory DB.
          medicationRepositoryBackendProvider.overrideWithValue(medRepo),
          chatRepositoryBackendProvider.overrideWithValue(chatRepo),
          appointmentRepositoryBackendProvider
              .overrideWithValue(AppointmentRepository(db, clock: _fixedNow)),
          providerRepositoryBackendProvider
              .overrideWithValue(ProviderRepository(db)),
          careCircleRepositoryBackendProvider
              .overrideWithValue(CareCircleRepository(db)),
          carePlanRepositoryBackendProvider
              .overrideWithValue(CarePlanRepository(db)),
          careEventsRepositoryBackendProvider
              .overrideWithValue(CareEventsRepository(db)),
          healthLogRepositoryBackendProvider
              .overrideWithValue(HealthLogRepository(db)),
          careTasksRepositoryBackendProvider
              .overrideWithValue(CareTasksRepository(db)),
          careShiftsRepositoryBackendProvider
              .overrideWithValue(CareShiftsRepository(db)),
          expensesRepositoryBackendProvider
              .overrideWithValue(ExpensesRepository(db)),
          documentsRepositoryBackendProvider
              .overrideWithValue(DocumentsRepository(db)),
          // A canned community feed so the Feed segment renders a stable
          // set of posts for the screenshot.
          forumApiClientProvider.overrideWithValue(_demoForumClient()),
        ],
      );
      addTearDown(container.dispose);

      // Boot at /onboarding so the §10.1 carousel → sign-in pre-conditions
      // run as written, independent of the production redirect wiring.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: HoldcloseApp(
            router: buildRouter(initialLocation: '/onboarding'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // ---- Pre-tour: welcome carousel + sign-in (§10.1 pre-conditions) ----
      expect(find.byKey(WelcomeCarousel.pageViewKey), findsOneWidget);
      for (int i = 0; i < 3; i++) {
        await tester.tap(find.byKey(WelcomeCarousel.primaryCtaKey));
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(SignInScreen.demoSkipButtonKey),
        findsOneWidget,
        reason: 'DEMO_MODE=true is required to expose the demo-skip CTA.',
      );
      await tester.tap(find.byKey(SignInScreen.demoSkipButtonKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // HOME — read the dashboard. Greeting + the Schedule card (which now
      // carries the day's medications, grouped by window) render. Capture
      // the landing.
      // ====================================================================
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget);
      expect(find.byKey(ScheduleCard.cardKey), findsOneWidget);
      await _capture(tester, '01_home');

      // ---- Profile icon → Settings → back to Home --------------------------
      // Settings is on the PathHeader pattern now: its title row carries the
      // back arrow (no AppBar BackButton, no word-labeled "Back to X").
      await tester.tap(find.byKey(PathHeader.profileButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(SettingsScreen.readAloudToggleKey), findsOneWidget);
      // "Settings" appears as both the page title and the terminal crumb.
      expect(find.text('Settings'), findsWidgets);
      await _tapHeaderBack(tester); // Home › Settings — back goes to Home.
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget);

      // Emergency Card is reached via the Care hub's tile (covered later in
      // the tour). The previous Home pin was removed; the Emergency Card
      // screen itself is still exercised below.

      // ---- The Schedule card's Morning dose group (Donepezil) → dose log →
      // back to Home --------------------------------------------------------
      // Tapping anywhere in today's window group (the med rows included)
      // pushes the dose log; the Care tab lights up since the dose log
      // lives in the Care branch.
      final Finder donepezilRow = find.text('Donepezil');
      expect(donepezilRow, findsWidgets);
      await tester.ensureVisible(donepezilRow.first);
      await tester.tap(donepezilRow.first);
      await tester.pumpAndSettle();
      expect(find.byKey(DoseLogScreen.listKey), findsOneWidget);
      // The dose log's parent crumb is Medications, so going home means the
      // Home crumb (the tab bar's Home label is not an InkWell, so this
      // can't mis-tap the bar).
      await _tapCrumb(tester, 'Home');
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget);

      // ====================================================================
      // CARE tab — the tile hub at /medical (renamed from "Medical";
      // 2026-06-06 IA refactor). Capture the landing.
      // ====================================================================
      await _tapTab(tester, 'Care');
      expect(
        find.byKey(MedicalHubScreen.tileKey('/medical/health-log')),
        findsOneWidget,
      );
      await _capture(tester, '02_care');

      // ---- Health Log tile → add an entry → back to the Care hub -----------
      await tester.tap(
        find.byKey(MedicalHubScreen.tileKey('/medical/health-log')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(HealthLogScreen.emptyStateKey), findsOneWidget);
      await tester.tap(find.byKey(HealthLogScreen.emptyCtaKey));
      await tester.pumpAndSettle();
      expect(find.byKey(HealthLogEntryForm.formKey), findsOneWidget);
      // A vitals entry needs at least one reading — a heart rate clears the
      // cross-field validator.
      await tester.enterText(
        find.byKey(HealthLogEntryForm.heartRateFieldKey),
        '72',
      );
      await tester.tap(find.byKey(HealthLogEntryForm.saveButtonKey));
      await tester.pumpAndSettle();
      // Back on the Health Log — the list now carries the saved entry.
      expect(find.byKey(HealthLogScreen.listKey), findsOneWidget);
      await _tapHeaderBack(tester); // Home › Care › Health Log — back to Care.
      expect(
        find.byKey(MedicalHubScreen.tileKey('/medical/routines')),
        findsOneWidget,
      );

      // ---- Routines tile → back to the Care hub (v2 Care Plan,
      // BUILD_SPEC.md §5.13 v2: slot/stage replaced by scheduled tasks).
      await tester.tap(
        find.byKey(MedicalHubScreen.tileKey('/medical/routines')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(CarePlanRoutinesScreen.emptyStateKey),
          findsOneWidget);
      await _tapHeaderBack(tester);
      expect(
        find.byKey(MedicalHubScreen.tileKey('/medical/cards/emergency')),
        findsOneWidget,
      );

      // ---- Emergency Card tile → open Emergency Card → back to Care --------
      // (Cards & Documents sub-hub + POA + IDs surfaces were removed;
      // Emergency Card is a top-level Care tile.)
      await tester.tap(
        find.byKey(MedicalHubScreen.tileKey('/medical/cards/emergency')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(EmergencyCardScreen.headlineKey), findsOneWidget);
      await _tapHeaderBack(tester);
      expect(
        find.byKey(MedicalHubScreen.tileKey('/medical/health-log')),
        findsOneWidget,
      );

      // ====================================================================
      // CARE CIRCLE — the former Team tab, now the Care hub's gated tile
      // (route stays /team). The tile is present because demo settings ship
      // teamCoordinationEnabled=true. Capture the hub landing.
      // ====================================================================
      await tester.tap(find.byKey(MedicalHubScreen.tileKey('/team')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(CareTeamHubScreen.tileKey('/team/circle')),
        findsOneWidget,
      );
      await _capture(tester, '03_care-circle');

      // ---- People tile → the roster + connect actions → back ---------------
      await tester.tap(find.byKey(CareTeamHubScreen.tileKey('/team/circle')));
      await tester.pumpAndSettle();
      // The People list is the backend circle; the connect strip lets you
      // set a @username, show your QR, scan, or add a caregiver by handle.
      expect(find.byKey(CareCircleScreen.usernameActionKey), findsOneWidget);
      expect(find.byKey(CareCircleScreen.addByUsernameActionKey),
          findsOneWidget);
      await _tapHeaderBack(tester); // … › Care Circle › People — back to hub.
      expect(
        find.byKey(CareTeamHubScreen.tileKey('/team/circle')),
        findsOneWidget,
      );

      // ====================================================================
      // CHAT tab — the conversation list. Capture the landing.
      // ====================================================================
      await _tapTab(tester, 'Chat');
      expect(find.byKey(ConversationListScreen.listKey), findsOneWidget);
      await _capture(tester, '04_chat');

      // ---- Open the first thread → send a message → the demo coach replies
      // → back to the list ---------------------------------------------------
      await tester.tap(
        find.byKey(ConversationListScreen.tileKey('convo-sundowning')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ChatScreen.listKey), findsOneWidget);
      // Under DEMO_MODE the chat backend is the deterministic
      // [DemoChatBackend], so the round-trip is exercised end to end: the
      // sent bubble AND the canned coach reply must both land in the thread.
      const String chatPrompt =
          'She was up wandering at 2 AM again. How do I get her back to sleep?';
      await tester.enterText(find.byKey(ChatScreen.inputFieldKey), chatPrompt);
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      await tester.pumpAndSettle();
      expect(find.text(chatPrompt), findsWidgets,
          reason: 'the sent message must appear in the thread');
      expect(find.text(DemoChatBackend.replyFor(chatPrompt)), findsWidgets,
          reason: 'the canned demo coach reply must stream back end-to-end');
      await _tapHeaderBack(tester); // Home › Chat › <thread> — back to Chat.
      expect(find.byKey(ConversationListScreen.listKey), findsOneWidget);

      // ====================================================================
      // COMMUNITY tab — the social feed fronted by the Feed/Learn/Support
      // sub-nav. Capture the landing, then swipe the three segments.
      // ====================================================================
      await _tapTab(tester, 'Community');
      expect(find.byKey(CommunityFeedScreen.listKey), findsOneWidget);
      expect(find.byKey(CommunityFeedScreen.subnavKey), findsOneWidget);
      await _capture(tester, '05_community');

      // Feed → Learn.
      await _tapSegment(tester, 'Learn');
      expect(find.byKey(CommunityFeedScreen.learnSegmentKey), findsOneWidget);
      // Learn → Support.
      await _tapSegment(tester, 'Support');
      expect(find.byKey(CommunityFeedScreen.supportSegmentKey), findsOneWidget);
      // Support → back to Feed.
      await _tapSegment(tester, 'Feed');
      expect(find.byKey(CommunityFeedScreen.listKey), findsOneWidget);
    },
    // The tour exercises the full app surface; give it generous headroom on
    // a real device where the demo backends' streaming + drift I/O add up.
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// Seed one chat thread (a user turn + a finished assistant reply) so the
/// conversation list renders it as an openable row.
Future<void> _seedThread(
  ChatRepository repo, {
  required String id,
  required DateTime createdAt,
  required String userText,
  required String assistantText,
}) async {
  await repo.createConversation(
    id: id,
    title: 'placeholder',
    createdAt: createdAt,
  );
  await repo.appendMessage(Message(
    id: '$id-u',
    conversationId: id,
    role: MessageRole.user,
    body: userText,
    citations: const <String>[],
    createdAt: createdAt,
    streamingDone: true,
  ));
  await repo.appendMessage(Message(
    id: '$id-a',
    conversationId: id,
    role: MessageRole.assistant,
    body: assistantText,
    citations: const <String>[],
    createdAt: createdAt.add(const Duration(minutes: 1)),
    streamingDone: true,
  ));
}

/// A canned [ForumApiClient] seeded with a deterministic Hot page so the
/// Community Feed renders the same posts every run.
ForumApiClient _demoForumClient() {
  ForumPost post(
    String id, {
    required String title,
    required String body,
    required int voteCount,
    required int commentCount,
    required Duration age,
  }) {
    final DateTime at = _fixedNow().subtract(age);
    return ForumPost(
      id: id,
      authorId: 'profile-$id',
      title: title,
      body: body,
      createdAt: at,
      updatedAt: at,
      voteCount: voteCount,
      hidden: false,
      commentCount: commentCount,
    );
  }

  return _CannedForumApiClient(<ForumPost>[
    post(
      'a',
      title: 'Sundowning hit hard at dusk again',
      body: 'We dimmed the lights and put on her favorite record. She '
          'settled in about ten minutes — sharing in case it helps another '
          'Careblazer tonight.',
      voteCount: 12,
      commentCount: 5,
      age: const Duration(minutes: 18),
    ),
    post(
      'b',
      title: 'Refusing the morning meds — what worked for you?',
      body: 'Hiding the pill in applesauce stopped working this week. I '
          'want to hear what other folks do for the routine itself.',
      voteCount: 7,
      commentCount: 9,
      age: const Duration(hours: 3),
    ),
  ]);
}

/// Same fake-client shape the widget + golden tests use — hands back a
/// fixed first page and an empty page for any pagination cursor.
class _CannedForumApiClient extends ForumApiClient {
  _CannedForumApiClient(this._page)
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final List<ForumPost> _page;

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async {
    if (before != null) return const <ForumPost>[];
    return _page;
  }
}

/// Capture a demo screenshot at a hub/tab landing.
///
/// Screenshots are regenerable VISUAL artifacts for pitch review, NOT an
/// exact-match gate: full-screen on-device captures aren't bit-stable
/// run-to-run (caret blink, antialiasing, animation-frame timing produce
/// sub-0.1% pixel jitter even between two runs of the identical build),
/// so a pixel-exact comparison flakes — and on integration_test the
/// mismatch surfaces as an UNHANDLED async error through `runAsync`,
/// which a local try/catch can't intercept. So we only touch the
/// baseline under `--update-goldens` ([autoUpdateGoldenFiles] true),
/// where `matchesGoldenFile` WRITES the PNG; on a normal run we skip the
/// comparison entirely. The tour's real regression gate is the
/// deterministic widget/text/navigation assertions at each landing —
/// a genuine breakage (wrong screen, missing widget) fails those hard
/// checks regardless. Regenerate the baselines before the pitch:
/// `flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true --update-goldens`.
Future<void> _capture(WidgetTester tester, String name) async {
  if (!autoUpdateGoldenFiles) return;
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/demo_tour_$name.png'),
  );
}

/// Tap a bottom-bar tab by its word [label], scoped to the custom
/// [TabScaffoldBar] (the 2026-06-06 IA refactor replaced Material's
/// NavigationBar with it) so a routed screen's matching body text can't
/// trap the finder. Mirrors `tabFor()` in test/integration/test_harness.dart.
/// Switching tabs `context.go`es to the branch root, so the destination
/// always lands on its hub regardless of any stacked feature page.
Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(TabScaffoldBar),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

/// Tap the [PathHeader]'s top-left back arrow — every feature page below a
/// hub carries one; it navigates to the parent crumb's route. (The
/// word-labeled "Back to X" control was removed as redundant with the
/// breadcrumb, so the arrow + parent crumb are the back affordances now.)
Future<void> _tapHeaderBack(WidgetTester tester) async {
  await tester.tap(find.byKey(PathHeader.backButtonKey));
  await tester.pumpAndSettle();
}

/// Tap a [PathHeader] breadcrumb crumb by its word [label]. Tappable crumbs
/// are `InkWell`s; the custom tab bar's items are `InkResponse`s, so a crumb
/// labeled like a tab (e.g. "Home") can't mis-resolve to the bottom bar.
Future<void> _tapCrumb(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(InkWell, label));
  await tester.pumpAndSettle();
}

/// Tap a [SegmentedSubnav] pill by its [label], scoped to the Community
/// sub-nav so a body's matching text can't trap the finder.
Future<void> _tapSegment(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(CommunityFeedScreen.subnavKey),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

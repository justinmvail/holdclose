import 'package:careblazers/app.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/models/forum.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/care_events_provider.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/care_shifts_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/providers/documents_provider.dart';
import 'package:careblazers/providers/expenses_provider.dart';
import 'package:careblazers/providers/health_log_provider.dart';
import 'package:careblazers/providers/home_clock_provider.dart';
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/providers/settings_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/chat/chat_screen.dart';
import 'package:careblazers/screens/chat/conversation_list_screen.dart';
import 'package:careblazers/screens/community/community_feed_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/medical/care_plan_routines_screen.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:careblazers/screens/medical/emergency_card_screen.dart';
import 'package:careblazers/screens/medical/health_log_entry_form.dart';
import 'package:careblazers/screens/medical/health_log_screen.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/screens/onboarding/sign_in_screen.dart';
import 'package:careblazers/screens/onboarding/welcome_carousel.dart';
import 'package:careblazers/screens/settings/settings_screen.dart';
import 'package:careblazers/screens/team/care_circle_screen.dart';
import 'package:careblazers/screens/team/care_team_hub_screen.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:careblazers/services/seed_repository.dart';
import 'package:careblazers/widgets/home/schedule_card.dart';
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

/// Scripted pitch walkthrough for the Phase 14 information architecture
/// (TASKS.md Phase 14.39, BUILD_SPEC.md §10.1).
///
/// The tour IS the test: each leg pairs a `tester.tap()` with at least one
/// `expect(...)`, so a regression on any screen surfaces as a hard test
/// failure rather than a silent pass-through. It walks the five-tab IA end
/// to end — Home dashboard → Settings → Emergency Card → dose log → the
/// Medical hub (Health Log add + Care Plan + Cards & Docs → Emergency
/// Card) → the Care Team hub (Care Circle → start an invite) → Chat (open
/// a thread) → Community (Feed → Learn → Support → Feed) — capturing a
/// demo screenshot on every tab landing.
///
/// Pre-conditions per §10.1:
///   * `DEMO_MODE=true` build define set (gates [FakeAuthProvider] + the
///     sign-in screen's "Skip — explore as Mary's caregiver" CTA).
///   * `FakeLLMProvider` for deterministic coaching copy — overridden
///     defensively so a build that flipped `USE_FAKE_LLM=false` still runs
///     against the canned responses.
///   * [InMemoryStorageProvider] pre-seeded with Mary Henderson + the demo
///     journal so the dashboard + Emergency Card land populated.
///   * A single in-memory [CareblazersDatabase] backs every drift
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
    'demo tour — Phase 14 five-tab IA walkthrough (BUILD_SPEC.md §10.1)',
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
      // each Medical / Team / Chat screen builds against a coherent store
      // instead of trying to open the on-device SQLite file.
      final CareblazersDatabase db =
          CareblazersDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // Seed the medication tracker so the Home "Medications Today" card —
      // and the dose log it taps through to — render a real dose row.
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
          child: CareblazersApp(
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

      // ---- Profile icon → Settings → close back to Home --------------------
      await tester.tap(find.byKey(PathHeader.profileButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(SettingsScreen.readAloudToggleKey), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      await _tapBack(tester); // Settings has an AppBar back button.
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget);

      // Emergency Card is now reached via Medical → Cards & Docs (covered
      // later in the tour). The previous Home pin was removed; the
      // Emergency Card screen itself is still exercised below.

      // ---- A Schedule medication (Donepezil, in the Morning window) →
      // dose log → back to Home -------------------------------------------
      final Finder donepezilRow = find.text('Donepezil');
      expect(donepezilRow, findsWidgets);
      await tester.ensureVisible(donepezilRow.first);
      await tester.tap(donepezilRow.first);
      await tester.pumpAndSettle();
      expect(find.byKey(DoseLogScreen.listKey), findsOneWidget);
      await _tapBack(tester); // Dose log has an AppBar back button.
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget);

      // ====================================================================
      // MEDICAL tab — the tile hub. Capture the landing.
      // ====================================================================
      await _tapTab(tester, 'Medical');
      expect(
        find.byKey(MedicalHubScreen.tileKey('/medical/health-log')),
        findsOneWidget,
      );
      await _capture(tester, '02_medical');

      // ---- Health Log tile → add an entry → back to Medical ----------------
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
      await _tapPathBack(tester, 'Back to Medical');
      expect(
        find.byKey(MedicalHubScreen.tileKey('/medical/care-plan')),
        findsOneWidget,
      );

      // ---- Routines tile → back to Medical (v2 Care Plan, BUILD_SPEC.md
      // §5.13 v2: slot/stage replaced by scheduled tasks).
      await tester.tap(
        find.byKey(MedicalHubScreen.tileKey('/medical/routines')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(CarePlanRoutinesScreen.emptyStateKey),
          findsOneWidget);
      await _tapPathBack(tester, 'Back to Medical');
      expect(
        find.byKey(MedicalHubScreen.tileKey('/medical/cards/emergency')),
        findsOneWidget,
      );

      // ---- Emergency Card tile → open Emergency Card → back to Medical -----
      // (Cards & Documents sub-hub + POA + IDs surfaces were removed;
      // Emergency Card is now a top-level Medical tile.)
      await tester.tap(
        find.byKey(MedicalHubScreen.tileKey('/medical/cards/emergency')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(EmergencyCardScreen.headlineKey), findsOneWidget);
      await _tapPathBack(tester, 'Back to Medical');
      expect(
        find.byKey(MedicalHubScreen.tileKey('/medical/health-log')),
        findsOneWidget,
      );

      // ====================================================================
      // TEAM tab — the Care Team tile hub. Capture the landing.
      // ====================================================================
      await _tapTab(tester, 'Team');
      expect(
        find.byKey(CareTeamHubScreen.tileKey('/team/circle')),
        findsOneWidget,
      );
      await _capture(tester, '03_team');

      // ---- Care Circle → the People list + connect actions → back to Team --
      await tester.tap(find.byKey(CareTeamHubScreen.tileKey('/team/circle')));
      await tester.pumpAndSettle();
      // The People list is the backend circle; the connect strip lets you
      // set a @username, show your QR, scan, or add a caregiver by handle.
      expect(find.byKey(CareCircleScreen.usernameActionKey), findsOneWidget);
      expect(find.byKey(CareCircleScreen.addByUsernameActionKey),
          findsOneWidget);
      await _tapPathBack(tester, 'Back to Care Circle');
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

      // ---- Open the first thread → back to the list ------------------------
      await tester.tap(
        find.byKey(ConversationListScreen.tileKey('convo-sundowning')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ChatScreen.listKey), findsOneWidget);
      await _tapPathBack(tester, 'Back to Chat');
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
    // a real device where the FakeLLM's streaming + drift I/O add up.
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

/// Capture a demo screenshot at a tab landing and assert it against the
/// committed baseline. `--update-goldens` regenerates the baseline.
Future<void> _capture(WidgetTester tester, String name) async {
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/demo_tour_$name.png'),
  );
}

/// Tap a bottom-tab destination by its [label], scoped to the
/// [NavigationBar] so a routed screen's matching title text can't trap the
/// finder.
Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

/// Tap the leading [BackButton] of the current AppBar (used by the screens
/// that keep their own app bar — Settings, dose log) and settle the pop.
Future<void> _tapBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).first);
  await tester.pumpAndSettle();
}

/// Tap a [PathHeader] word-labeled Back control (an `InkWell` over the
/// [label] text) and settle the pop.
Future<void> _tapPathBack(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
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

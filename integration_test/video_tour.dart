import 'dart:io';

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
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/decoder/decoder_result_screen.dart';
import 'package:careblazers/screens/decoder/triage_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/screens/medication/medication_list_screen.dart';
import 'package:careblazers/screens/onboarding/sign_in_screen.dart';
import 'package:careblazers/screens/onboarding/welcome_carousel.dart';
import 'package:careblazers/screens/team/care_team_hub_screen.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/chat_service.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:careblazers/services/seed_repository.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:careblazers/widgets/tab_scaffold.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Human-paced pitch-video walkthrough — the recordable sibling of
/// `demo_tour.dart`.
///
/// Differences from the demo tour, all in service of a watchable
/// screen recording rather than a regression gate:
///   * Runs at the device's NATIVE surface size (no setSurfaceSize) so
///     the captured frames are exactly what a phone shows.
///   * `framePolicy = fullyLive` + wall-clock holds between actions,
///     so animations/streaming render in real time on screen.
///   * Drives the Behavior Decoder end-to-end (accusing → Night /
///     Don't know / Tried to explain → script) — the wedge the demo
///     tour skips — and starts from an EMPTY journal so the auto-log
///     beat ("your journal fills itself") happens on camera.
///   * Optional host sync: with `--dart-define=SYNC_FILE=<path>` the
///     tour prints VIDEO_TOUR_READY and idles on the carousel until
///     the host (which starts `simctl recordVideo` on READY) creates
///     that file — so the recording contains no build dead-time.
///
/// Run (recorded by tools/record_video_tour.sh):
///
///     flutter test integration_test/video_tour.dart \
///       --dart-define=DEMO_MODE=true \
///       --dart-define=SYNC_FILE=/tmp/cb_video_sync \
///       -d <simulator-id>
DateTime _fixedNow() => DateTime(2026, 6, 12, 11, 0);

const String _syncFile =
    String.fromEnvironment('SYNC_FILE', defaultValue: '');

final Stopwatch _clock = Stopwatch();

void _cue(String label) {
  final double t = _clock.elapsedMilliseconds / 1000.0;
  debugPrint('VIDEO_CUE ${t.toStringAsFixed(1)}s  $label');
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Render every frame live so streaming text + page transitions are
  // visible in the recording while the test idles in wall-clock holds.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'video tour — recordable pitch walkthrough (decoder wedge included)',
    (WidgetTester tester) async {
      if (!demoModeEnabled) {
        fail('video_tour.dart requires --dart-define=DEMO_MODE=true.');
      }

      // Mary only — NO sample journal. The decoder's auto-log is the
      // "journal fills itself" beat, so it must start empty.
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      await SeedRepository(storage: storage).ensurePatient();

      final CareblazersDatabase db =
          CareblazersDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // A realistic regimen across two dose windows so the Home schedule
      // card and the Medications list read as a lived-in app on camera.
      final MedicationRepository medRepo =
          MedicationRepository(db, clock: _fixedNow);
      await medRepo.upsertMedication(const Medication(
        id: 'med-don',
        name: 'Donepezil',
        dosage: '10 mg',
        route: MedicationRoute.oral,
      ));
      await medRepo.upsertMedication(const Medication(
        id: 'med-mem',
        name: 'Memantine',
        dosage: '10 mg',
        route: MedicationRoute.oral,
      ));
      await medRepo.upsertMedication(const Medication(
        id: 'med-vitd',
        name: 'Vitamin D',
        dosage: '2000 IU',
        route: MedicationRoute.oral,
      ));
      await medRepo.upsertWindow(const DoseWindow(
        id: 'window-demo-patient-mary-morning',
        patientId: 'demo-patient-mary',
        label: 'Morning',
        anchorTime: TimeOfDay(hour: 8, minute: 0),
        sortOrder: 0,
      ));
      await medRepo.upsertWindow(const DoseWindow(
        id: 'window-demo-patient-mary-evening',
        patientId: 'demo-patient-mary',
        label: 'Evening',
        anchorTime: TimeOfDay(hour: 19, minute: 0),
        sortOrder: 1,
      ));
      await medRepo.upsertEntry(MedicationWindowEntry(
        id: 'entry-don-morning',
        medicationId: 'med-don',
        windowId: 'window-demo-patient-mary-morning',
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      await medRepo.upsertEntry(MedicationWindowEntry(
        id: 'entry-vitd-morning',
        medicationId: 'med-vitd',
        windowId: 'window-demo-patient-mary-morning',
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));
      await medRepo.upsertEntry(MedicationWindowEntry(
        id: 'entry-mem-evening',
        medicationId: 'med-mem',
        windowId: 'window-demo-patient-mary-evening',
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ));

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
        id: 'convo-shower',
        createdAt: _fixedNow().subtract(const Duration(hours: 3)),
        userText: 'He refuses to shower and gets angry when I bring it up.',
        assistantText:
            'Make it about comfort, not hygiene — warm the bathroom first, '
            'keep the routine identical, and let him own the steps.',
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
          chatLLMBackendProvider.overrideWithValue(const DemoChatBackend()),
          ttsProvider.overrideWith((Ref ref) => const NoopTTSProvider()),
          ttsSettingsProvider
              .overrideWith((Ref ref) => ref.watch(settingsProvider)),
          homeClockProvider.overrideWithValue(_fixedNow),
          doseLogClockProvider.overrideWithValue(_fixedNow),
          communityFeedClockProvider.overrideWithValue(_fixedNow),
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
          forumApiClientProvider.overrideWithValue(_demoForumClient()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: CareblazersApp(
            router: buildRouter(initialLocation: '/onboarding'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(WelcomeCarousel.pageViewKey), findsOneWidget);

      // ---- Host sync: idle on carousel page 1 until the recorder runs ----
      if (_syncFile.isNotEmpty) {
        debugPrint('VIDEO_TOUR_READY');
        final File marker = File(_syncFile);
        final DateTime deadline =
            DateTime.now().add(const Duration(seconds: 150));
        while (!marker.existsSync() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      _clock.start();
      debugPrint('VIDEO_TOUR_START');

      // ==== SCENE 1 — welcome carousel: logo, pocket coach, journal ======
      _cue('scene 1: carousel page 1 (logo)');
      await _hold(tester, 2.5);
      await _tap(tester, find.byKey(WelcomeCarousel.primaryCtaKey));
      _cue('scene 1: carousel page 2 (pocket coach)');
      await _hold(tester, 3.0);
      await _tap(tester, find.byKey(WelcomeCarousel.primaryCtaKey));
      _cue('scene 1: carousel page 3 (journal fills itself)');
      await _hold(tester, 2.5);
      await _tap(tester, find.byKey(WelcomeCarousel.primaryCtaKey));
      _cue('scene 1: sign-in');
      await _hold(tester, 1.5);
      await _tap(tester, find.byKey(SignInScreen.demoSkipButtonKey));
      await _hold(tester, 1.0);

      // ==== SCENE 2 — Home dashboard ======================================
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget);
      _cue('scene 2: Home dashboard (greeting + schedule)');
      await _hold(tester, 4.0);

      // ==== SCENE 3 — Care hub → empty Journal → decoder ==================
      await _tapTab(tester, 'Care');
      expect(
        find.byKey(MedicalHubScreen.tileKey('/journal')),
        findsOneWidget,
      );
      _cue('scene 3: Care hub tiles');
      await _hold(tester, 2.5);
      await _tap(tester, find.byKey(MedicalHubScreen.tileKey('/journal')));
      expect(find.byKey(JournalScreen.emptyCtaKey), findsOneWidget);
      _cue('scene 3: empty Journal ("fills itself")');
      await _hold(tester, 3.0);
      await _tap(tester, find.byKey(JournalScreen.emptyCtaKey));

      // ==== SCENE 4 — the Behavior Decoder (the wedge) ====================
      expect(find.byKey(BehaviorPickerScreen.gridKey), findsOneWidget);
      _cue('scene 4: behavior picker');
      await _hold(tester, 3.0);
      await _tap(tester, find.byKey(BehaviorPickerScreen.cardKey('accusing')));
      _cue('scene 4: triage Q1 (when)');
      await _hold(tester, 1.2);
      await _tap(tester, find.byKey(TriageScreen.optionKey(0, 3))); // Night
      await _hold(tester, 0.7);
      await _tap(tester, find.byKey(TriageScreen.nextButtonKey));
      _cue('scene 4: triage Q2 (what changed)');
      await _hold(tester, 1.0);
      await _tap(tester, find.byKey(TriageScreen.optionKey(1, 5))); // Don't know
      await _hold(tester, 0.6);
      await _tap(tester, find.byKey(TriageScreen.nextButtonKey));
      _cue('scene 4: triage Q3 (what tried)');
      await _hold(tester, 1.0);
      await _tap(tester, find.byKey(TriageScreen.optionKey(2, 1))); // Explain
      await _hold(tester, 0.6);
      await _tap(tester, find.byKey(TriageScreen.nextButtonKey));

      // ==== SCENE 5 — the script streams in ===============================
      _cue('scene 5: decoder result streaming');
      await _hold(tester, 2.0); // skeleton → stream completes
      expect(find.byType(DecoderResultScreen), findsOneWidget);
      await _hold(tester, 6.0); // read "say" lines
      await _scroll(tester, find.byType(DecoderResultScreen), -350);
      _cue('scene 5: tweak + dont-say');
      await _hold(tester, 3.0);
      await _scroll(tester, find.byType(DecoderResultScreen), -350);
      _cue('scene 5: footer + Talk to Natali');
      await _hold(tester, 3.0);
      // "That helped" — logs the outcome on the auto-created journal row
      // and closes the loop by returning Home (context.go('/')).
      final Finder thatHelped = find.byKey(DecoderResultScreen.thatHelpedKey);
      if (tester.any(thatHelped)) {
        await _tap(tester, thatHelped, warn: false);
        _cue('scene 5: That helped → back Home');
        await _hold(tester, 2.0);
        // ==== SCENE 6 — the journal filled itself =========================
        await _tapTab(tester, 'Care');
        await _hold(tester, 0.8);
        await _tap(tester, find.byKey(MedicalHubScreen.tileKey('/journal')));
      } else {
        // Fallback (copy change): walk the breadcrumb out of the decoder.
        await _tapCrumb(tester, 'Journal');
      }
      expect(find.byKey(JournalScreen.entriesListKey), findsOneWidget);
      _cue('scene 6: Journal auto-logged the moment');
      await _hold(tester, 3.5);

      // ==== SCENE 7 — Care suite: medications + emergency card ============
      await _tapCrumb(tester, 'Care');
      await _hold(tester, 1.5);
      await _tap(
          tester, find.byKey(MedicalHubScreen.tileKey('/medications')));
      expect(find.byKey(MedicationListScreen.listKey), findsOneWidget);
      _cue('scene 7: medications + dose windows');
      await _hold(tester, 3.0);
      await _tapHeaderBack(tester);
      await _hold(tester, 0.8);
      await _tap(
        tester,
        find.byKey(MedicalHubScreen.tileKey('/medical/cards/emergency')),
      );
      _cue('scene 7: Emergency Card');
      await _hold(tester, 3.0);
      await _scroll(tester, find.byType(MaterialApp), -250);
      await _hold(tester, 2.0);
      await _tapHeaderBack(tester);
      await _hold(tester, 0.8);

      // ==== SCENE 8 — Care Circle hub =====================================
      await _tap(tester, find.byKey(MedicalHubScreen.tileKey('/team')));
      expect(
        find.byKey(CareTeamHubScreen.tileKey('/team/circle')),
        findsOneWidget,
      );
      _cue('scene 8: Care Circle (calendar/tasks/shifts/expenses)');
      await _hold(tester, 3.5);

      // ==== SCENE 9 — Chat coach ==========================================
      await _tapTab(tester, 'Chat');
      expect(find.byKey(ConversationListScreen.listKey), findsOneWidget);
      _cue('scene 9: conversation list');
      await _hold(tester, 2.0);
      await _tap(
        tester,
        find.byKey(ConversationListScreen.tileKey('convo-sundowning')),
      );
      await _hold(tester, 1.5);
      const String chatPrompt =
          'She was up wandering at 2 AM again. How do I get her back to sleep?';
      _cue('scene 9: typing');
      await _type(tester, find.byKey(ChatScreen.inputFieldKey), chatPrompt);
      await _hold(tester, 0.5);
      await _tap(tester, find.byKey(ChatScreen.sendButtonKey));
      _cue('scene 9: coach reply streams');
      await _hold(tester, 5.0);

      // ==== SCENE 10 — Community: feed + Learn ============================
      await _tapTab(tester, 'Community');
      expect(find.byKey(CommunityFeedScreen.listKey), findsOneWidget);
      _cue('scene 10: community feed');
      await _hold(tester, 3.0);
      await _tapSegment(tester, 'Learn');
      _cue('scene 10: Learn — the frameworks');
      await _hold(tester, 4.0);

      _cue('end');
      await _hold(tester, 2.0);
      debugPrint('VIDEO_TOUR_END');
      // Give the host a beat to stop the recorder before teardown blanks
      // the screen.
      await _hold(tester, 3.0);
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

// ---------------------------------------------------------------------------
// Pacing helpers — wall-clock holds with live frames
// ---------------------------------------------------------------------------

/// Idle for [seconds] of real time while the engine keeps painting
/// (framePolicy fullyLive). Pumps periodically so pending widget-tree
/// work (stream chunks, futures) integrates promptly.
Future<void> _hold(WidgetTester tester, double seconds) async {
  final DateTime end = DateTime.now()
      .add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester tester, Finder finder,
    {bool warn = true}) async {
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first, warnIfMissed: warn);
  await tester.pump();
  // Let the transition/animation play out on screen.
  await _hold(tester, 0.6);
}

/// Type [text] into [field] character by character so the keyboard-less
/// recording still reads as someone writing a message.
Future<void> _type(WidgetTester tester, Finder field, String text) async {
  await tester.showKeyboard(field);
  final StringBuffer typed = StringBuffer();
  for (final String char in text.split('')) {
    typed.write(char);
    tester.testTextInput.enterText(typed.toString());
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  await tester.pump();
}

/// Animated drag (with momentum) on the screen surface — a visible,
/// human-looking scroll.
Future<void> _scroll(WidgetTester tester, Finder surface, double dy) async {
  await tester.timedDragFrom(
    tester.getCenter(surface.first),
    Offset(0, dy),
    const Duration(milliseconds: 700),
  );
  await tester.pump();
  await _hold(tester, 0.5);
}

Future<void> _tapTab(WidgetTester tester, String label) async {
  await _tap(
    tester,
    find.descendant(
      of: find.byType(TabScaffoldBar),
      matching: find.text(label),
    ),
  );
}

Future<void> _tapHeaderBack(WidgetTester tester) async {
  await _tap(tester, find.byKey(PathHeader.backButtonKey));
}

Future<void> _tapCrumb(WidgetTester tester, String label) async {
  await _tap(tester, find.widgetWithText(InkWell, label));
}

Future<void> _tapSegment(WidgetTester tester, String label) async {
  await _tap(
    tester,
    find.descendant(
      of: find.byKey(CommunityFeedScreen.subnavKey),
      matching: find.text(label),
    ),
  );
}

// ---------------------------------------------------------------------------
// Seeds — same shapes as demo_tour.dart
// ---------------------------------------------------------------------------

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
    post(
      'c',
      title: '"I want to go home" — but we ARE home',
      body: 'Dad asks to go home every evening. I finally stopped '
          'correcting him and started asking what he misses about it. '
          'The change in him was immediate.',
      voteCount: 21,
      commentCount: 11,
      age: const Duration(hours: 5),
    ),
    post(
      'd',
      title: 'Small win: music during dinner',
      body: 'Putting the radio on low during meals stopped the pacing '
          'almost completely. Three nights in a row now. Take the small '
          'wins, Careblazers.',
      voteCount: 9,
      commentCount: 3,
      age: const Duration(days: 1),
    ),
  ]);
}

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

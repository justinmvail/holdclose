import 'dart:io';

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
import 'package:holdclose/screens/journal/journal_screen.dart';
import 'package:holdclose/screens/journal/journal_wizard_screen.dart';
import 'package:holdclose/screens/medical/medical_hub_screen.dart';
import 'package:holdclose/screens/medication/dose_log_screen.dart';
import 'package:holdclose/screens/medication/medication_list_screen.dart';
import 'package:holdclose/screens/onboarding/sign_in_screen.dart';
import 'package:holdclose/screens/onboarding/welcome_carousel.dart';
import 'package:holdclose/screens/team/care_team_hub_screen.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/chat_service.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:holdclose/services/seed_repository.dart';
import 'package:holdclose/widgets/path_header.dart';
import 'package:holdclose/widgets/tab_scaffold.dart';
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
///   * Starts from an EMPTY journal and authors a journal entry on
///     camera (the quick-note path), so the "your journal, in your
///     words" beat happens live.
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
    'video tour — recordable pitch walkthrough',
    (WidgetTester tester) async {
      if (!demoModeEnabled) {
        fail('video_tour.dart requires --dart-define=DEMO_MODE=true.');
      }

      // Mary only — NO sample journal, so the journal starts empty and the
      // caregiver authors the first entry on camera.
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      await SeedRepository(storage: storage).ensurePatient();

      final HoldcloseDatabase db =
          HoldcloseDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // A realistic regimen across two dose windows so the Home schedule
      // card and the Medications list read as a lived-in app on camera.
      final MedicationRepository medRepo =
          MedicationRepository(db, clock: _fixedNow);
      await medRepo.upsertMedication(const Medication(
        id: 'med-don',
        name: 'Lisinopril',
        dosage: '10 mg',
        route: MedicationRoute.oral,
      ));
      await medRepo.upsertMedication(const Medication(
        id: 'med-mem',
        name: 'Atorvastatin',
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
          child: HoldcloseApp(
            router: buildRouter(initialLocation: '/onboarding'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(WelcomeCarousel.pageViewKey), findsOneWidget);

      // Skip onboarding carousel + demo sign-in -> Home.
      await _tap(tester, find.byKey(WelcomeCarousel.primaryCtaKey));
      await _tap(tester, find.byKey(WelcomeCarousel.primaryCtaKey));
      await _tap(tester, find.byKey(WelcomeCarousel.primaryCtaKey));
      await _tap(tester, find.byKey(SignInScreen.demoSkipButtonKey));
      await _hold(tester, 1.2);
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget);

      // Prepare the iOS surface for image capture, then shoot each screen.
      await binding.convertFlutterSurfaceToImage();
      await _hold(tester, 1.0);
      await binding.takeScreenshot('01_home');

      await _tapTab(tester, 'Care');
      await _hold(tester, 1.0);
      await binding.takeScreenshot('02_care_hub');

      await _tap(tester, find.byKey(MedicalHubScreen.tileKey('/medications')));
      await _hold(tester, 1.0);
      await binding.takeScreenshot('03_medications');
      await _tapHeaderBack(tester);
      await _hold(tester, 0.6);

      await _tap(
        tester,
        find.byKey(MedicalHubScreen.tileKey('/medical/cards/emergency')),
      );
      await _hold(tester, 1.0);
      await binding.takeScreenshot('04_emergency_card');

      await _tapTab(tester, 'Chat');
      await _hold(tester, 1.0);
      await binding.takeScreenshot('05_chat');

      await _tapTab(tester, 'Community');
      await _hold(tester, 1.0);
      await binding.takeScreenshot('06_community');
    },
    timeout: const Timeout(Duration(minutes: 6)),
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
          'caregiver tonight.',
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
          'wins, Holdclose.',
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

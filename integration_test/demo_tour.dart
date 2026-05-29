import 'package:careblazers/app.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/providers/settings_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/crisis/crisis_card_screen.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/decoder/decoder_result_screen.dart';
import 'package:careblazers/screens/decoder/triage_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:careblazers/screens/library/library_card_screen.dart';
import 'package:careblazers/screens/library/library_screen.dart';
import 'package:careblazers/screens/onboarding/sign_in_screen.dart';
import 'package:careblazers/screens/onboarding/welcome_carousel.dart';
import 'package:careblazers/screens/settings/settings_screen.dart';
import 'package:careblazers/seed/chat_system_prompt.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/chat_service.dart';
import 'package:careblazers/services/seed_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/message_body.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Scripted pitch walkthrough (BUILD_SPEC.md §10.1).
///
/// The tour IS the test: each of the eighteen numbered steps below pairs
/// a `tester.tap()` with at least one `expect(...)`, so a regression on
/// any screen surfaces as a hard test failure rather than a silent
/// pass-through. Pre-conditions per §10.1:
///
///   * `DEMO_MODE=true` build define set (gates [FakeAuthProvider] +
///     the sign-in screen's "Skip — explore as Mary's caregiver" CTA).
///   * `FakeLLMProvider` for deterministic decoder scripts — overridden
///     here defensively so a build that flipped `USE_FAKE_LLM=false`
///     still runs the tour against the canned responses.
///   * `InMemoryStorageProvider` pre-seeded with [maryHenderson] + the
///     six [sampleJournalEntries] so the journal lands populated, just
///     like the production `maybeResetForDemo` bootstrap would.
///   * [NoopTTSProvider] so PLAY taps don't try to spin up the
///     `flutter_tts` platform channel on the test host.
///
/// Run it as:
///
///     flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'demo tour — BUILD_SPEC.md §10.1 eighteen-step pitch walkthrough',
    (WidgetTester tester) async {
      if (!demoModeEnabled) {
        fail(
          'demo_tour.dart requires --dart-define=DEMO_MODE=true so '
          'FakeAuthProvider + the sign-in demo-skip button are active.',
        );
      }

      // Tall surface so the decoder result + library card detail render
      // without scroll-gating the outcome buttons. setSurfaceSize is a
      // no-op on real devices; on a real device the actual viewport
      // applies and we fall back to `ensureVisible` below.
      await tester.binding.setSurfaceSize(const Size(420, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);

      // Bake the same seed [main.maybeResetForDemo] would lay down when
      // booting into demo mode: Mary's crisis card + six dated journal
      // entries (BUILD_SPEC.md §9.1 + §9.2).
      await SeedRepository(storage: storage).populateAll();

      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageBackendProvider.overrideWithValue(storage),
          llmProvider.overrideWithValue(const FakeLLMProvider()),
          ttsProvider.overrideWith((Ref ref) => const NoopTTSProvider()),
          // Mirror main.dart: pipe SettingsNotifier through the TTS
          // settings selector so the Step-18 "Read scripts aloud" toggle
          // can flip the muting state without per-screen plumbing.
          ttsSettingsProvider
              .overrideWith((Ref ref) => ref.watch(settingsProvider)),
        ],
      );
      addTearDown(container.dispose);

      // Inject a router that boots at /onboarding so the §10.1 carousel
      // → sign-in pre-conditions run as written, regardless of whether
      // the production redirect (task 31) is wired up yet.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: CareblazersApp(
            router: buildRouter(initialLocation: '/onboarding'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // ---- Pre-tour: welcome carousel + sign-in (§10.1 pre-conditions) -----
      expect(find.byKey(WelcomeCarousel.pageViewKey), findsOneWidget);
      // Three CTA taps: page 1 → page 2 → page 3 → /sign-in.
      for (int i = 0; i < 3; i++) {
        await tester.tap(find.byKey(WelcomeCarousel.primaryCtaKey));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(SignInScreen.demoSkipButtonKey), findsOneWidget,
          reason: 'DEMO_MODE=true is required to expose the demo-skip CTA.');
      await tester.tap(find.byKey(SignInScreen.demoSkipButtonKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 1 — Home: assert "What's happening right now?" + tap the
      // primary target.
      // ====================================================================
      expect(find.byKey(HomeScreen.primaryTargetKey), findsOneWidget);
      expect(find.text("What's happening"), findsOneWidget);
      await tester.tap(find.byKey(HomeScreen.primaryTargetKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 2 — Behavior picker: assert all 8 canonical cards + tap
      // Sundowning.
      // ====================================================================
      expect(find.byKey(BehaviorPickerScreen.gridKey), findsOneWidget);
      for (final String id in const <String>[
        'upset',
        'refusing_care',
        'wants_home',
        'asking_for_someone',
        'accusing',
        'sundowning',
        'wandering',
        'hallucinating',
      ]) {
        expect(
          find.byKey(BehaviorPickerScreen.cardKey(id)),
          findsOneWidget,
          reason: 'Behavior card "$id" should render in the §5.2 grid',
        );
      }
      await tester
          .tap(find.byKey(BehaviorPickerScreen.cardKey('sundowning')));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 3 — Triage Q1: "Late afternoon / evening" + Next.
      // ====================================================================
      expect(find.text('When does it tend to happen?'), findsOneWidget);
      await tester.tap(find.byKey(TriageScreen.optionKey(0, 2)));
      await tester.pump();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 4 — Triage Q2: "Nothing" + Next.
      // ====================================================================
      expect(find.text('What changed recently?'), findsOneWidget);
      await tester.tap(find.byKey(TriageScreen.optionKey(1, 0)));
      await tester.pump();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 5 — Triage Q3: "Talked to them about it" + Next.
      // ====================================================================
      expect(find.text('What have you already tried?'), findsOneWidget);
      await tester.tap(find.byKey(TriageScreen.optionKey(2, 0)));
      await tester.pump();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 6 — Decoder result (sundowning): assert the FakeLLM script
      // renders (3 say lines + 1 tweak + 1 don't-say) + tap "That helped".
      // ====================================================================
      expect(find.text('Dr. Natali says:'), findsOneWidget);
      for (int i = 0; i < 3; i++) {
        expect(find.byKey(DecoderResultScreen.sayLineKey(i)), findsOneWidget);
      }
      expect(find.byKey(DecoderResultScreen.tweakLineKey(0)), findsOneWidget);
      expect(
        find.byKey(DecoderResultScreen.dontSayLineKey(0)),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(DecoderResultScreen.thatHelpedKey));
      await tester.tap(find.byKey(DecoderResultScreen.thatHelpedKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 7 — Home (returned via "That helped"): assert + re-open the
      // decoder to lead into the second flow.
      // ====================================================================
      expect(find.byKey(HomeScreen.primaryTargetKey), findsOneWidget);
      await tester.tap(find.byKey(HomeScreen.primaryTargetKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 8 — Behavior picker → Accusing me.
      // ====================================================================
      expect(
        find.byKey(BehaviorPickerScreen.cardKey('accusing')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(BehaviorPickerScreen.cardKey('accusing')));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 9 — Triage: Late afternoon / evening, Nothing, Tried to
      // explain → push result. Q1 assertion anchors the step.
      // ====================================================================
      expect(find.text('When does it tend to happen?'), findsOneWidget);
      await _answerTriageAll(tester, q1: 2, q2: 0, q3: 1);

      // ====================================================================
      // STEP 10 — Decoder result (accusing): assert + That helped.
      // ====================================================================
      expect(find.text('Dr. Natali says:'), findsOneWidget);
      expect(find.byKey(DecoderResultScreen.sayLineKey(0)), findsOneWidget);
      await tester.ensureVisible(find.byKey(DecoderResultScreen.thatHelpedKey));
      await tester.tap(find.byKey(DecoderResultScreen.thatHelpedKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 11 — Home → behavior picker → "I want to go home".
      // ====================================================================
      expect(find.byKey(HomeScreen.primaryTargetKey), findsOneWidget);
      await tester.tap(find.byKey(HomeScreen.primaryTargetKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(BehaviorPickerScreen.cardKey('wants_home')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(BehaviorPickerScreen.cardKey('wants_home')));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 12 — Triage: Evening (late afternoon / evening), Nothing,
      // Walked away → result.
      // ====================================================================
      expect(find.text('When does it tend to happen?'), findsOneWidget);
      await _answerTriageAll(tester, q1: 2, q2: 0, q3: 2);

      // ====================================================================
      // STEP 13 — Decoder result (wants_home): assert + That helped.
      // ====================================================================
      expect(find.text('Dr. Natali says:'), findsOneWidget);
      expect(find.byKey(DecoderResultScreen.sayLineKey(0)), findsOneWidget);
      await tester.ensureVisible(find.byKey(DecoderResultScreen.thatHelpedKey));
      await tester.tap(find.byKey(DecoderResultScreen.thatHelpedKey));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 14 — Journal tab: assert week summary card + the "Heads up"
      // pattern alert. Seeded entries already cross the §7.6
      // new-behaviors threshold (≥3 distinct behaviors in 14 days), so
      // the card is present without depending on the (precise but
      // tighter) sundowning rule firing.
      // ====================================================================
      await _tapTab(tester, 'Journal');
      expect(find.byKey(JournalScreen.weekSummaryKey), findsOneWidget);
      expect(find.byKey(JournalScreen.patternAlertKey), findsOneWidget);

      // ====================================================================
      // STEP 15 — Library tab: assert Today's card + tap the Sundowning
      // tile in the most-asked-behaviors list.
      // ====================================================================
      await _tapTab(tester, 'Library');
      expect(find.byKey(LibraryScreen.todaysCardKey), findsOneWidget);
      final Finder sundowningTile =
          find.byKey(LibraryScreen.cardTileKey('sundowning_basics'));
      expect(sundowningTile, findsOneWidget);
      await tester.ensureVisible(sundowningTile);
      await tester.tap(sundowningTile);
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 16 — Library card detail: assert body + PLAY, then tap PLAY.
      // The TTS provider is the no-op so the speak call is a synchronous
      // success — we're verifying the UI wiring, not the audio engine.
      // ====================================================================
      expect(find.byKey(LibraryCardScreen.bodyTextKey), findsOneWidget);
      expect(find.byKey(LibraryCardScreen.playButtonKey), findsOneWidget);
      await tester.tap(find.byKey(LibraryCardScreen.playButtonKey));
      await tester.pumpAndSettle();
      // Pop back to the library tab so the next tab switch lands on a
      // tab root — keeps the §4.1 navigation invariant intact.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // ====================================================================
      // STEP 17 — Crisis tab: Mary Henderson loaded from the seed.
      // ====================================================================
      await _tapTab(tester, 'Crisis');
      // Wait for the post-frame bootstrap microtask to upsert the seed
      // patient and rebuild — `pumpAndSettle` already covered the first
      // frame, but the crisis card's `_bootstrap` schedules an async
      // future that resolves on the next event loop turn.
      await tester.pumpAndSettle();
      expect(find.byKey(CrisisCardScreen.cardKey), findsOneWidget);
      expect(find.text('Mary Henderson'), findsAtLeastNWidgets(1));

      // ====================================================================
      // STEP 18 — Settings (via gear from Home): toggle "Read scripts
      // aloud" OFF, assert, toggle ON, assert, close.
      // ====================================================================
      await _tapTab(tester, 'Home');
      expect(find.byKey(HomeScreen.settingsGearKey), findsOneWidget);
      await tester.tap(find.byKey(HomeScreen.settingsGearKey));
      await tester.pumpAndSettle();
      expect(find.byKey(SettingsScreen.readAloudToggleKey), findsOneWidget);

      expect(
        _readAloudValue(tester),
        isTrue,
        reason: 'Default settings should boot with audio ON.',
      );
      await tester.tap(find.byKey(SettingsScreen.readAloudToggleKey));
      await tester.pumpAndSettle();
      expect(_readAloudValue(tester), isFalse);
      await tester.tap(find.byKey(SettingsScreen.readAloudToggleKey));
      await tester.pumpAndSettle();
      expect(_readAloudValue(tester), isTrue);

      // Close settings — pop the route and land back on Home.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(HomeScreen.primaryTargetKey), findsOneWidget);
    },
    // Tour exercises the full app surface; give it generous headroom on
    // a real device where the FakeLLM's 60ms-per-chunk streaming adds up
    // across three decoder flows.
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // ============================================================================
  // Chat citation deep-link walkthrough (TASKS.md Phase 11.6 acceptance).
  //
  // The acceptance shape from the task brief is:
  //     "open chat tab, type 'what's sundowning?', verify a response
  //      streams in with at least one library card citation, tap the
  //      citation, verify navigation lands on the library screen."
  //
  // The "open chat tab + enter text" surface (the chat tab in the bottom
  // bar, ConversationListScreen, ChatScreen) is owned by Phase 11.4 and
  // is not yet landed. This block exercises the half of the chain that
  // CAN be tested today against the shipped pieces:
  //
  //   * [ChatService] (Phase 11.3) streams a scripted assistant reply
  //     through the real persistence layer (in-memory drift) using a
  //     scripted [ChatLLMBackend] in place of the shim — same shape the
  //     `chat_service_test.dart` unit suite uses.
  //   * The assistant reply ends in a `[card:sundowning_basics]` marker;
  //     [ChatService.parseCitations] lifts it onto [Message.citations].
  //   * The [MessageBody] widget (Phase 11.5) is pumped inside a
  //     minimal [GoRouter] wired with the real [LibraryCardScreen] at
  //     `/library/:id` — the same route the chat screens will call into
  //     once 11.4 ships.
  //   * Tapping the rendered citation chip pushes `/library/sundowning_basics`
  //     and the [LibraryCardScreen] renders, completing the user-facing
  //     citation → library navigation chain the brief asks us to gate.
  //
  // Once 11.4 lands the chat tab + ChatScreen + the `chatEnabled`
  // settings flag, the first half of this block (DB + ChatService +
  // direct widget pump) becomes:
  //     `await _tapTab(tester, 'Chat')` →
  //     `await tester.enterText(..., "what's sundowning?")` →
  //     `await tester.tap(send)` → tap chip → expect library.
  // ============================================================================
  testWidgets(
    'demo tour — chat reply citation chip deep-links to library '
    '(TASKS.md Phase 11.5 + 11.6)',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // ---- Stream a citation-bearing assistant reply through ChatService ----
      final CareblazersDatabase db =
          CareblazersDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final ChatRepository repo = ChatRepository(db);
      await repo.createConversation(
        id: 'convo-tour',
        title: "what's sundowning?",
        createdAt: DateTime.utc(2026, 5, 29, 23, 0),
      );

      final _CitedSundowningBackend backend = _CitedSundowningBackend();
      int idCounter = 0;
      final ChatService chat = ChatService(
        repository: repo,
        backend: backend,
        idFactory: () => 'tour-msg-${++idCounter}',
        clock: () => DateTime.utc(2026, 5, 29, 23, 0),
      );

      final List<Message> emitted = await chat
          .sendMessage(
            conversationId: 'convo-tour',
            userText: "what's sundowning?",
          )
          .toList();

      // ChatService yields: the user turn, the empty assistant placeholder,
      // one snapshot per text delta, and a final snapshot with citations
      // parsed + streamingDone flipped true.
      expect(emitted.first.role, MessageRole.user);
      expect(emitted.first.body, "what's sundowning?");
      final Message assistant = emitted.last;
      expect(assistant.role, MessageRole.assistant);
      expect(
        assistant.streamingDone,
        isTrue,
        reason: 'Phase 11.6: the assistant reply must finish streaming '
            'before the chip can be rendered + tapped.',
      );
      expect(
        assistant.citations,
        contains('sundowning_basics'),
        reason: 'Phase 11.6 acceptance: the chat reply must cite at least '
            'one library card; sundowning is the seed scenario.',
      );
      expect(backend.callCount, 1);
      expect(
        backend.lastSystemPrompt,
        chatSystemPrompt,
        reason: 'ChatService must forward the verbatim Phase 11.3 chat '
            'system prompt — voice + citation contract depend on it.',
      );

      // ---- Pump MessageBody under a router that owns /library/:id ----
      // The route registration mirrors `lib/routing/router.dart` — same
      // builder shape — so when 11.4 wires the chat screens onto the
      // production router, MessageBody chips continue to land at the
      // same destination without any indirection.
      final GoRouter router = GoRouter(
        initialLocation: '/chat-tour-host',
        routes: <RouteBase>[
          GoRoute(
            path: '/chat-tour-host',
            builder: (BuildContext context, GoRouterState state) {
              return Scaffold(
                backgroundColor: careblazersColors.background,
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: MessageBody(body: assistant.body),
                  ),
                ),
              );
            },
          ),
          GoRoute(
            path: '/library/:id',
            builder: (BuildContext context, GoRouterState state) =>
                LibraryCardScreen(
              cardId: state.pathParameters['id'] ?? '',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            routerConfig: router,
            theme: careblazersLightTheme,
            debugShowCheckedModeBanner: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // ---- Verify the chip rendered, then tap it. ----
      final Finder chip = find.byKey(
        MessageBody.citationChipKey('sundowning_basics'),
      );
      expect(
        chip,
        findsOneWidget,
        reason: 'MessageBody (Phase 11.5) must render one chip per cited '
            'library card; the sundowning_basics marker must surface as '
            "a tap target labelled 'Dr. Natali on ...'.",
      );
      expect(
        find.text('Dr. Natali on What\'s happening between 4pm and bedtime'),
        findsOneWidget,
        reason: 'Chip label resolves <card:id> → LibraryCard.title from '
            'lib/seed/library_cards.dart (the sundowning_basics title).',
      );

      await tester.tap(chip);
      await tester.pumpAndSettle();

      // ---- Land on the library card screen for sundowning_basics. ----
      expect(
        find.byType(LibraryCardScreen),
        findsOneWidget,
        reason: 'Phase 11.6 acceptance: tapping the citation chip must '
            'navigate to the library card screen for the cited id.',
      );
      expect(find.byKey(LibraryCardScreen.titleTextKey), findsOneWidget);
      expect(find.byKey(LibraryCardScreen.bodyTextKey), findsOneWidget);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Scripted [ChatLLMBackend] for the Phase 11.6 demo-tour walkthrough.
///
/// Yields a sundowning answer in two text chunks ending with a
/// `[card:sundowning_basics]` citation marker, then closes the stream
/// cleanly so [ChatService] flips `streamingDone: true` on the final
/// snapshot. Captures the system prompt + history each call so the
/// walkthrough can assert the canonical prompt flowed through.
///
/// Mirrors the pattern in `test/services/chat_service_test.dart`'s
/// `_ScriptedChatBackend`; kept private to the tour file so the demo's
/// canned phrasing doesn't drift the unit tests.
class _CitedSundowningBackend implements ChatLLMBackend {
  int callCount = 0;
  String? lastSystemPrompt;
  List<ChatTurn>? lastHistory;

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    callCount++;
    lastSystemPrompt = systemPrompt;
    lastHistory = history;
    yield const ChatDeltaText(
      'Sundowning is the late-afternoon shift many Careblazers notice in '
      'their loved ones — agitation, restlessness, sometimes wanting to '
      'leave. ',
    );
    yield const ChatDeltaText(
      'It is not a moral failing or a bad day; the brain is mid-transition '
      'and the fading light pulls the rug out from under their orientation. '
      '[card:sundowning_basics]',
    );
  }
}

/// Read the current value of the Settings "Read scripts aloud"
/// [SwitchListTile]. Helper so the toggle assertions read top-to-bottom
/// without re-typing the descendant find each time.
bool _readAloudValue(WidgetTester tester) {
  final SwitchListTile tile = tester.widget<SwitchListTile>(
    find.byKey(SettingsScreen.readAloudToggleKey),
  );
  return tile.value;
}

/// Walk all three triage questions in one helper. The picker pushes
/// `/decoder/triage` with an empty answers object; we tap option [q1]
/// then Next, then [q2] then Next, then [q3] then Next — landing on
/// `/decoder/result`. Indices match the order in [TriageScreen]'s option
/// tables (§5.3).
Future<void> _answerTriageAll(
  WidgetTester tester, {
  required int q1,
  required int q2,
  required int q3,
}) async {
  await tester.tap(find.byKey(TriageScreen.optionKey(0, q1)));
  await tester.pump();
  await tester.tap(find.byKey(TriageScreen.nextButtonKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(TriageScreen.optionKey(1, q2)));
  await tester.pump();
  await tester.tap(find.byKey(TriageScreen.nextButtonKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(TriageScreen.optionKey(2, q3)));
  await tester.pump();
  await tester.tap(find.byKey(TriageScreen.nextButtonKey));
  await tester.pumpAndSettle();
}

/// Tap the bottom-tab destination with [label] and settle the branch
/// switch. The label match is scoped to descendants of [NavigationBar]
/// so the route's AppBar title (e.g. the Journal screen's "Journal"
/// text) doesn't ambiguity-trap the finder.
Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

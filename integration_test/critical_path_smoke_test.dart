import 'package:holdclose/app.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/documents_provider.dart';
import 'package:holdclose/providers/expenses_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/llm_provider.dart';
import 'package:holdclose/providers/settings_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/tts_provider.dart';
import 'package:holdclose/routing/router.dart';
import 'package:holdclose/screens/chat/chat_screen.dart';
import 'package:holdclose/screens/chat/conversation_list_screen.dart';
import 'package:holdclose/screens/home_screen.dart';
import 'package:holdclose/screens/onboarding/loved_one_setup_screen.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/chat_service.dart';
import 'package:holdclose/services/fake_forum_api_client.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Critical-path SMOKE tests — run the REAL app on a device/simulator and
/// drive the flows the demo tour skips and that broke during alpha:
/// **loved-one setup** (the save that hung on "Saving…") and **end-to-end
/// chat** (a send that posted nothing back).
///
/// Unlike the widget tests (which fake everything and never navigate the
/// real router), these boot the actual `HoldcloseApp` + real router +
/// real screens + real on-DB repositories. They fake only the two things a
/// test must NOT hit — OAuth (the system sign-in sheet) and the LLM/network
/// — so a regression in the wiring between fails here, not on a tester's
/// phone.
///
/// Run on the booted simulator (reliable) or a plugged-in phone:
///   flutter test integration_test/critical_path_smoke_test.dart \
///     -d <device-id> --dart-define=DEMO_MODE=true
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'set up loved one → land on Home → every tab opens',
    (WidgetTester tester) async {
      _requireDemoMode();
      final InMemoryStorageProvider storage =
          await _bootApp(tester, initialLocation: '/setup');

      // The setup wizard renders.
      expect(find.byKey(LovedOneSetupScreen.nameFieldKey), findsOneWidget,
          reason: 'the loved-one setup wizard should render');

      // The flow that hung on "Saving…": fill the name, save.
      await tester.enterText(
          find.byKey(LovedOneSetupScreen.nameFieldKey), 'Mom');
      await tester.tap(find.byKey(LovedOneSetupScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // Save must PERSIST and route to Home — if it hangs or never flips the
      // gate, Home never renders and this fails.
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget,
          reason: 'setup save must persist the loved one and land on Home');
      final patient = await storage.getPatient();
      expect(patient?.name, 'Mom', reason: 'the saved loved one must persist');

      // Every tab opens without crashing (real router + screens).
      for (final String tab in <String>['Care', 'Chat', 'Community', 'Home']) {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
      }
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget);
    },
  );

  testWidgets(
    'chat end-to-end — start a chat, send a message, get a reply back',
    (WidgetTester tester) async {
      _requireDemoMode();
      await _bootApp(tester, initialLocation: '/chat');

      // Empty conversation list → start a quick chat.
      expect(find.byKey(ConversationListScreen.emptyStateKey), findsOneWidget,
          reason: 'a fresh install has no chat threads');
      await tester.tap(find.byKey(ConversationListScreen.emptyQuickChatKey));
      await tester.pumpAndSettle();

      // The chat screen renders its composer.
      expect(find.byKey(ChatScreen.inputFieldKey), findsOneWidget);

      // Send a message — the full ChatService path: persist user turn →
      // stream the (faked) reply → render it. This is the exact path that
      // failed with "database is locked" / "Couldn't reach the coach".
      await tester.enterText(find.byKey(ChatScreen.inputFieldKey), 'hello');
      await tester.tap(find.byKey(ChatScreen.sendButtonKey));
      await tester.pumpAndSettle();

      // Both the user message AND the coach's reply land in the thread.
      expect(find.text('hello'), findsWidgets,
          reason: 'the sent message must appear');
      expect(find.text('Here to help.'), findsWidgets,
          reason: 'the coach reply must come back end-to-end');
    },
  );
}

void _requireDemoMode() {
  if (!demoModeEnabled) {
    fail('Run with --dart-define=DEMO_MODE=true (enables FakeAuth so the test '
        'never hits real OAuth).');
  }
}

/// Boots the real app with OAuth + the LLM/chat backend faked and every
/// repository on ONE shared in-memory DB (the production single-connection
/// shape), at [initialLocation]. Returns the storage so a test can assert
/// what persisted.
Future<InMemoryStorageProvider> _bootApp(
  WidgetTester tester, {
  required String initialLocation,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  addTearDown(storage.dispose);

  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  addTearDown(db.close);

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      storageBackendProvider.overrideWithValue(storage),
      // Fake only what a test must not touch: the LLM + chat backend (no
      // shim / network) and TTS.
      llmProvider.overrideWithValue(const FakeLLMProvider()),
      chatLLMBackendProvider.overrideWithValue(const _FakeChatBackend()),
      ttsProvider.overrideWith((Ref ref) => const NoopTTSProvider()),
      ttsSettingsProvider
          .overrideWith((Ref ref) => ref.watch(settingsProvider)),
      // Every repository on the one shared in-memory DB.
      medicationRepositoryBackendProvider
          .overrideWithValue(MedicationRepository(db)),
      chatRepositoryBackendProvider.overrideWithValue(ChatRepository(db)),
      appointmentRepositoryBackendProvider
          .overrideWithValue(AppointmentRepository(db)),
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
      // No backend — sync no-ops, the community shows the canned fake.
      forumApiClientProvider.overrideWithValue(FakeForumApiClient()),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      // The redirect GATE that funnels users between onboarding/setup/home is
      // wired by main.dart (not buildRouter), so in-test we boot straight to
      // the screen under test and exercise it + its real navigation directly.
      child: HoldcloseApp(router: buildRouter(initialLocation: initialLocation)),
    ),
  );
  await tester.pumpAndSettle();
  return storage;
}

/// Deterministic chat backend — yields one canned reply, no shim/network.
class _FakeChatBackend implements ChatLLMBackend {
  const _FakeChatBackend();

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    yield const ChatDeltaText('Here to help.');
  }
}

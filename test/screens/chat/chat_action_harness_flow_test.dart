import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/chat/chat_screen.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/chat_service.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Closes the audit gap "no test drives the chat action harness through the
/// real chat UI." Pumps the live [ChatScreen] (which uses the real
/// `chatServiceProvider` + `buildChatActions`), scripts the coach's reply to
/// carry an `[action:…]` marker, sends a message, and asserts the side
/// effect actually happened — a medication written, or the app navigated.

const String _convoId = 'c1';

/// Scripted backend that streams [deltas] then closes.
class _ScriptedBackend implements ChatLLMBackend {
  _ScriptedBackend(this.deltas);
  final List<ChatDelta> deltas;

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    for (final ChatDelta d in deltas) {
      yield d;
    }
  }
}

Future<({MedicationRepository meds, GoRouter router})> _pumpThread(
  WidgetTester tester, {
  required HoldcloseDatabase db,
  required List<ChatDelta> reply,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final ChatRepository chatRepo = ChatRepository(db);
  await chatRepo.createConversation(
      id: _convoId, title: 'thread', createdAt: DateTime(2026, 6, 1));
  final MedicationRepository meds = MedicationRepository(db);

  final GoRouter router = GoRouter(
    initialLocation: '/chat/$_convoId',
    routes: <RouteBase>[
      GoRoute(
        path: '/chat/:id',
        builder: (BuildContext c, GoRouterState s) =>
            ChatScreen(conversationId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/medications',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('MED LIST'))),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        chatRepositoryBackendProvider.overrideWithValue(chatRepo),
        chatLLMBackendProvider.overrideWithValue(_ScriptedBackend(reply)),
        medicationRepositoryBackendProvider.overrideWithValue(meds),
        // The chat now reads the user's data for context each turn — point
        // every data backend at the in-memory DB so it doesn't hit the real
        // on-device SQLite (which throws in a widget test).
        storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
        appointmentRepositoryBackendProvider
            .overrideWithValue(AppointmentRepository(db)),
        carePlanRepositoryBackendProvider
            .overrideWithValue(CarePlanRepository(db)),
        healthLogRepositoryBackendProvider
            .overrideWithValue(HealthLogRepository(db)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (meds: meds, router: router);
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(ChatScreen.inputFieldKey), text);
  await tester.tap(find.byKey(ChatScreen.sendButtonKey));
  await tester.pumpAndSettle();
}

String _location(GoRouter router) =>
    router.routerDelegate.currentConfiguration.last.matchedLocation;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HoldcloseDatabase db;

  setUp(() => db = HoldcloseDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  testWidgets('an add_medication action in the reply writes the med + strips '
      'the marker from the bubble', (WidgetTester tester) async {
    final ({MedicationRepository meds, GoRouter router}) h = await _pumpThread(
      tester,
      db: db,
      reply: const <ChatDelta>[
        ChatDeltaText('Done — I added it.\n'
            '[action:add_medication name="Aspirin" dosage="81 mg"]'),
      ],
    );

    await _send(tester, 'add aspirin 81 mg');

    // The tool ran through the real ChatService → the med is on disk.
    final List<Medication> meds = await h.meds.listMedications();
    expect(meds, hasLength(1));
    expect(meds.single.name, 'Aspirin');
    expect(meds.single.dosage, '81 mg');
    // The raw marker is stripped; only the prose shows.
    expect(find.textContaining('Done — I added it.'), findsOneWidget);
    expect(find.textContaining('[action:'), findsNothing);
  });

  testWidgets('a navigate action in the reply pushes the target screen',
      (WidgetTester tester) async {
    final ({MedicationRepository meds, GoRouter router}) h = await _pumpThread(
      tester,
      db: db,
      reply: const <ChatDelta>[
        ChatDeltaText('Taking you there.\n'
            '[action:navigate target="medications"]'),
      ],
    );

    expect(_location(h.router), '/chat/$_convoId');

    await _send(tester, 'take me to her meds');

    // The chat screen's navigation listener pushed the medication list.
    expect(_location(h.router), '/medications');
    expect(find.text('MED LIST'), findsOneWidget);
  });
}

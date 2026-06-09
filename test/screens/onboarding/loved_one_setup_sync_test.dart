import 'package:careblazers/db/database.dart';
import 'package:careblazers/l10n/app_localizations.dart';
import 'package:careblazers/models/forum.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/care_events_provider.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/care_shifts_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/providers/documents_provider.dart';
import 'package:careblazers/providers/expenses_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/sync_state_provider.dart';
import 'package:careblazers/providers/health_log_provider.dart';
import 'package:careblazers/screens/onboarding/loved_one_setup_screen.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:careblazers/services/sync_service.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// Fail-safe regression (server-authoritative sync): the first-loved-one
/// onboarding save must still work when the sync backend is unreachable —
/// the patient is saved locally, the screen navigates to Home, and no
/// crash escapes. The backend here throws on every call.
class _ThrowingForumApiClient extends ForumApiClient {
  _ThrowingForumApiClient()
      : super(
          tokenLoader: (() async => 'tok'),
          baseUrl: 'https://unreachable.invalid',
        );

  @override
  Future<CircleDto> createCircle(String name, {SyncPatientWrite? patient}) =>
      throw ForumApiException(statusCode: 0, error: 'transport_error');

  @override
  Future<List<CircleDto>> listCircles() =>
      throw ForumApiException(statusCode: 0, error: 'transport_error');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
    'first loved one saves locally + navigates to Home when sync backend '
    'is unreachable',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);

      final CareblazersDatabase db =
          CareblazersDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final MedicationRepository medications = MedicationRepository(db);

      final SyncController controller = SyncController(
        outbox: SyncOutbox(db),
        client: _ThrowingForumApiClient(),
        stateStore: const SyncStateStore(),
        storage: storage,
        medications: medications,
        chat: ChatRepository(db),
        appointments: AppointmentRepository(db),
        providers: ProviderRepository(db),
        healthLog: HealthLogRepository(db),
        carePlan: CarePlanRepository(db),
        careEvents: CareEventsRepository(db),
        careTasks: CareTasksRepository(db),
        careShifts: CareShiftsRepository(db),
        expenses: ExpensesRepository(db),
        careCircle: CareCircleRepository(db),
        documents: DocumentsRepository(db),
      );
      addTearDown(controller.dispose);

      final GoRouter router = GoRouter(
        initialLocation: '/setup',
        routes: <RouteBase>[
          GoRoute(
            path: '/setup',
            builder: (BuildContext context, GoRouterState state) =>
                const LovedOneSetupScreen(),
          ),
          GoRoute(
            path: '/',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: Center(child: Text('test-home'))),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            storageBackendProvider.overrideWithValue(storage),
            patientSetupIdFactoryProvider.overrideWithValue(() => 'p-1'),
            syncControllerProvider.overrideWith((Ref ref) => controller),
          ],
          child: MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(LovedOneSetupScreen.nameFieldKey),
        'Mary Henderson',
      );
      final Finder save = find.byKey(LovedOneSetupScreen.saveButtonKey);
      await tester.scrollUntilVisible(save, 300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(save);
      await tester.pumpAndSettle();

      // Navigated to Home despite the backend throwing.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/',
      );
      expect(find.text('test-home'), findsOneWidget);

      // The loved one is saved locally.
      final Patient? saved = await storage.getPatient();
      expect(saved?.name, 'Mary Henderson');

      // No circle was bound (the create threw) — fully local, as today.
      expect(await const SyncStateStore().getCircleId(), isNull);
    },
  );
}

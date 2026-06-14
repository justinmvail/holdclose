import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/forum.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/care_events_provider.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/care_shifts_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/providers/circle_member_cache_provider.dart';
import 'package:careblazers/providers/documents_provider.dart';
import 'package:careblazers/providers/expenses_provider.dart';
import 'package:careblazers/providers/health_log_provider.dart';
import 'package:careblazers/providers/loved_one_lookup_provider.dart';
import 'package:careblazers/providers/patient_configured_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/sync_state_provider.dart';
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:careblazers/services/sync_service.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// A forum client that records whether [listCircles] was reached (proving
/// the adopt short-circuit) and can simulate an unreachable backend.
class _RecordingClient extends ForumApiClient {
  _RecordingClient({this.throwOnList = false})
      : super(
          tokenLoader: (() async => 'tok'),
          baseUrl: 'https://test.invalid',
        );

  final bool throwOnList;
  int listCircleCalls = 0;

  @override
  Future<List<CircleDto>> listCircles() async {
    listCircleCalls += 1;
    if (throwOnList) {
      throw ForumApiException(statusCode: 0, error: 'transport_error');
    }
    return const <CircleDto>[];
  }

  @override
  Future<SyncPullResult> syncPull(String circleId, {int since = 0}) async =>
      const SyncPullResult(cursor: 0, patient: null, docs: <SyncDoc>[]);
}

SyncController _buildSync(
  CareblazersDatabase db,
  StorageProvider storage,
  ForumApiClient client,
) =>
    SyncController(
      outbox: SyncOutbox(db),
      client: client,
      stateStore: const SyncStateStore(),
      storage: storage,
      medications: MedicationRepository(db),
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
      circleMemberCache: CircleMemberCacheRepository(db),
    );

ProviderContainer _container({
  required StorageProvider storage,
  required ForumApiClient client,
}) {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final SyncController sync = _buildSync(db, storage, client);
  addTearDown(sync.dispose);

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      storageBackendProvider.overrideWithValue(storage),
      syncControllerProvider.overrideWith((Ref ref) => sync),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('begin() engages the gate, end() releases it', () {
    final InMemoryStorageProvider storage = InMemoryStorageProvider();
    addTearDown(storage.dispose);
    final ProviderContainer container =
        _container(storage: storage, client: _RecordingClient());

    final LovedOneLookup lookup =
        container.read(lovedOneLookupProvider.notifier);
    expect(container.read(lovedOneLookupProvider), isFalse);

    lookup.begin();
    expect(container.read(lovedOneLookupProvider), isTrue,
        reason: 'begin() holds the /setup gate before the OAuth round-trip');

    lookup.end();
    expect(container.read(lovedOneLookupProvider), isFalse,
        reason: 'end() releases it so the redirect decides setup-vs-home');
  });

  test(
    'adopt() short-circuits (never touches the backend) when a loved one is '
    'already on file locally',
    () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      await storage.upsertPatient(maryHenderson());

      final _RecordingClient client = _RecordingClient();
      final ProviderContainer container =
          _container(storage: storage, client: client);

      // Resolve the gate flag to its real value first (the seeded patient).
      await container.read(patientConfiguredProvider.notifier).reload();
      expect(container.read(patientConfiguredProvider), isTrue);

      await container.read(lovedOneLookupProvider.notifier).adopt();

      expect(client.listCircleCalls, 0,
          reason: 'a loved one already on this device needs no backend lookup');
    },
  );

  test('adopt() is fail-safe: a throwing backend never escapes', () async {
    final InMemoryStorageProvider storage = InMemoryStorageProvider();
    addTearDown(storage.dispose);
    // Empty store → the lookup runs; the backend throws on every call.
    final _RecordingClient client = _RecordingClient(throwOnList: true);
    final ProviderContainer container =
        _container(storage: storage, client: client);

    // Must complete without throwing.
    await container.read(lovedOneLookupProvider.notifier).adopt();

    expect(client.listCircleCalls, greaterThanOrEqualTo(1),
        reason: 'with no local loved one the backend lookup is attempted');
    // Nothing was adopted, so the setup gate stays closed — the caller
    // (redirect) then proceeds to /setup exactly as before.
    await container.read(patientConfiguredProvider.notifier).reload();
    expect(container.read(patientConfiguredProvider), isFalse);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/l10n/app_localizations.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/models/forum.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/care_events_provider.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/care_shifts_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/providers/documents_provider.dart';
import 'package:careblazers/providers/expenses_provider.dart';
import 'package:careblazers/providers/health_log_provider.dart';
import 'package:careblazers/providers/home_conversation_provider.dart';
import 'package:careblazers/providers/onboarding_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/sync_state_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/onboarding/loved_one_setup_screen.dart';
import 'package:careblazers/screens/onboarding/sign_in_screen.dart';
import 'package:careblazers/seed/mary_henderson.dart';
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

/// End-to-end regression for the fresh-sign-in loved-one lookup
/// (fb 2026-06-13). A returning caregiver signing in on a new install has
/// NO loved one on this device yet, but their account already owns one on
/// the backend. Before this fix the `/setup` gate (which keys off the LOCAL
/// patient only) forced them to create a DUPLICATE person, which sync then
/// shadowed with their original as the active one. This drives the REAL
/// router redirect + the REAL sign-in screen + the REAL
/// [lovedOneLookupProvider] against a faked backend, asserting the existing
/// loved one is adopted and the wizard is skipped.

/// Backend whose account ALREADY owns a loved one: its single circle
/// carries the [patient], so `bootstrapCircle` adopts the circle and writes
/// the loved one onto this device.
class _BackendWithLovedOne extends ForumApiClient {
  _BackendWithLovedOne(this._patient)
      : super(
          tokenLoader: (() async => 'tok'),
          baseUrl: 'https://test.invalid',
        );

  final Patient _patient;

  @override
  Future<List<CircleDto>> listCircles() async => <CircleDto>[
        CircleDto(
          id: 'circle-1',
          name: "${_patient.name}'s circle",
          ownerProfileId: 'owner-1',
          createdAt: DateTime.utc(2026, 1, 1),
          patient: SyncPatient(
            payload: jsonEncode(_patient.toJson()),
            clientUpdatedAt: 1,
            rev: 1,
          ),
        ),
      ];

  @override
  Future<SyncPullResult> syncPull(String circleId, {int since = 0}) async =>
      const SyncPullResult(cursor: 0, patient: null, docs: <SyncDoc>[]);

  @override
  Future<SyncPushResult> syncPush(
    String circleId, {
    SyncPatientWrite? patient,
    required List<SyncDocWrite> docs,
  }) async =>
      const SyncPushResult(
        cursor: 0,
        patient: null,
        applied: <({String id, int rev, bool accepted})>[],
      );
}

/// Backend whose account owns NO circle yet — the genuinely-new-caregiver
/// case. `bootstrapCircle` finds nothing to adopt, so the setup wizard is
/// correctly shown (the original behavior, preserved).
class _BackendWithNoCircles extends ForumApiClient {
  _BackendWithNoCircles()
      : super(
          tokenLoader: (() async => 'tok'),
          baseUrl: 'https://test.invalid',
        );

  @override
  Future<List<CircleDto>> listCircles() async => const <CircleDto>[];

  @override
  Future<SyncPullResult> syncPull(String circleId, {int since = 0}) async =>
      const SyncPullResult(cursor: 0, patient: null, docs: <SyncDoc>[]);
}

/// Auth spy whose Google flow flips the machine to signed-in — the same
/// transition the real backend-verified Google path produces, without the
/// OAuth plugins.
class _SpyAuth implements AuthProvider {
  AuthState _state = const AuthState.signedOut();
  final StreamController<AuthState> _changes =
      StreamController<AuthState>.broadcast();

  static const User _user = User(
    id: 'returning-caregiver',
    email: 'caregiver@careblazers.app',
    name: 'Returning Caregiver',
  );

  Future<void> dispose() => _changes.close();

  @override
  Stream<AuthState> watchAuthState() async* {
    yield _state;
    yield* _changes.stream;
  }

  @override
  Future<void> signInWithApple() async =>
      _emit(const AuthState.signedIn(user: _user));

  @override
  Future<void> signInWithGoogle() async =>
      _emit(const AuthState.signedIn(user: _user));

  @override
  Future<void> signOut() async => _emit(const AuthState.signedOut());

  @override
  Future<void> deleteAccount() async => _emit(const AuthState.signedOut());

  void _emit(AuthState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }
}

/// Reports onboarding as already complete so the redirect's first gate
/// passes and the app lands on `/sign-in` (mirrors a returning install).
class _AlreadyOnboarded extends OnboardingCompleted {
  @override
  bool build() => true;
}

/// A fake-backed [SyncController] over an in-memory drift db that SHARES
/// [storage] with the app, so an adopted loved one is visible to the
/// `/setup` gate.
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
    );

/// Pump the production [careblazersRouterProvider] (real redirect + sign-in
/// screen + loved-one lookup) over [auth] + [client], returning the live
/// pieces the test asserts against. Onboarding is pre-completed and the
/// store starts EMPTY, so the app boots on `/sign-in`.
Future<({GoRouter router, InMemoryStorageProvider storage})> _pump(
  WidgetTester tester, {
  required _SpyAuth auth,
  required ForumApiClient client,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final DateTime now = DateTime.utc(2026, 5, 30, 12);
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  addTearDown(storage.dispose);

  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final SyncController sync = _buildSync(db, storage, client);
  addTearDown(sync.dispose);

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      authProvider.overrideWithValue(auth),
      storageBackendProvider.overrideWithValue(storage),
      onboardingCompletedProvider.overrideWith(_AlreadyOnboarded.new),
      // The fresh-sign-in lookup reads the sync engine — back it with the
      // in-memory db + faked client so the backend round-trip is
      // deterministic and shares the app's storage.
      syncControllerProvider.overrideWith((Ref ref) => sync),
      // Home renders a chat scaffold off this; hand it a synthetic
      // conversation so the landing doesn't blank on a storage read.
      homeConversationProvider.overrideWith(
        (_) async => Conversation(
          id: 'lookup-flow-conv',
          title: 'Today',
          createdAt: now,
          updatedAt: now,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);

  final GoRouter router = container.read(careblazersRouterProvider);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        // Android platform so the sign-in screen shows the Google button
        // (and hides the iOS-only Apple button) deterministically. The
        // brand theme is intentionally omitted — its google_fonts futures
        // fail in a unit test; `context.cb` falls back without it.
        theme: ThemeData(platform: TargetPlatform.android),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, storage: storage);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'returning caregiver whose account already owns a loved one adopts it '
    'and skips /setup (no duplicate)',
    (WidgetTester tester) async {
      final _SpyAuth auth = _SpyAuth();
      addTearDown(auth.dispose);
      final Patient mary = maryHenderson();

      final ({GoRouter router, InMemoryStorageProvider storage}) pumped =
          await _pump(tester, auth: auth, client: _BackendWithLovedOne(mary));

      // Onboarded but signed-out → the sign-in screen, no wizard yet.
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(LovedOneSetupScreen), findsNothing);

      // Sign in: the fresh-sign-in lookup adopts the account's existing
      // loved one off the backend BEFORE the /setup gate can force a dup.
      await tester.tap(find.byKey(SignInScreen.googleButtonKey));
      await tester.pumpAndSettle();

      // Landed on Home, having NEVER shown the setup wizard.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(LovedOneSetupScreen), findsNothing);
      expect(pumped.router.routerDelegate.currentConfiguration.uri.path, '/');

      // Their existing loved one was pulled onto this device (not re-created)
      // and the backend's circle was adopted, not a brand-new one minted.
      final Patient? adopted = await pumped.storage.getPatient();
      expect(adopted?.name, mary.name);
      expect(await const SyncStateStore().getCircleId(), 'circle-1');
    },
  );

  testWidgets(
    'genuinely new caregiver (account owns no loved one) still lands on '
    '/setup',
    (WidgetTester tester) async {
      final _SpyAuth auth = _SpyAuth();
      addTearDown(auth.dispose);

      final ({GoRouter router, InMemoryStorageProvider storage}) pumped =
          await _pump(tester, auth: auth, client: _BackendWithNoCircles());

      expect(find.byType(SignInScreen), findsOneWidget);

      await tester.tap(find.byKey(SignInScreen.googleButtonKey));
      await tester.pumpAndSettle();

      // No loved one anywhere → the setup wizard, exactly as before the fix.
      expect(find.byType(LovedOneSetupScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(await pumped.storage.getPatient(), isNull);
    },
  );
}

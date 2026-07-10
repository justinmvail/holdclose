/// Shared harness for every Phase 15 `test/integration/*_flow_test.dart`
/// (TASKS.md Phase 15.1). Pumps the full [HoldcloseApp] over fake
/// backends, an in-memory drift database, and a pinned clock so flows
/// assert real navigation + persistence without a device, a live LLM, or
/// the on-disk SQLite file.
///
/// Every flow test calls [pumpHoldcloseApp] first, optionally seeds via
/// [seedMaryHenderson] / [seedDashboard], then drives the UI with the
/// shared finders ([homeGreeting], [tabFor], [pathHeaderBackTo],
/// [findHubTile]). URL hand-offs are captured by [FakeUrlLauncher] so
/// outbound-link assertions never fire a platform plugin.
library;

import 'package:holdclose/app.dart';
import 'package:holdclose/widgets/tab_scaffold.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart';
import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/analytics_provider.dart';
import 'package:holdclose/providers/auth_provider.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/home_clock_provider.dart';
import 'package:holdclose/providers/link_launcher_provider.dart';
import 'package:holdclose/providers/llm_provider.dart';
import 'package:holdclose/providers/onboarding_provider.dart';
import 'package:holdclose/providers/patient_configured_provider.dart';
import 'package:holdclose/providers/quiet_hours_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/tts_provider.dart';
import 'package:holdclose/routing/router.dart';
import 'package:holdclose/screens/appointment/appointment_list_screen.dart'
    show appointmentListClockProvider;
import 'package:holdclose/screens/home_screen.dart';
import 'package:holdclose/screens/medication/dose_log_screen.dart'
    show doseLogClockProvider;
import 'package:holdclose/screens/team/care_team_hub_screen.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/seed/sample_journal.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:holdclose/widgets/hub_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// `Override` lives in riverpod_annotation in this pinned riverpod major;
// flutter_riverpod doesn't re-export it (matches the existing widget-test
// harnesses' import).
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// The fixed wall-clock instant the harness pins every clock provider to
/// unless a test passes its own. 2026-06-01 11:00 local — a Monday
/// late-morning, matching the demo seed's "today" and CLAUDE.md's
/// `currentDate`. Morning so the Home greeting reads "Good morning" and
/// the night-theme flip stays off.
final DateTime kHarnessClock = DateTime(2026, 6, 1, 11, 0);

/// Captures every URL handed to `url_launcher` instead of opening it
/// (TASKS.md Phase 15.1 — used by 15.4 / 15.9 / 15.19 / 15.20 / 15.21).
///
/// Wired in as the [linkLauncherProvider] override so the decoder
/// result's "Talk to Natali" CTA, the Care Circle phone/email actions,
/// and the Settings destructive-link surfaces all record their URIs here
/// for assertion. [launch] always reports success so callers that branch
/// on the bool stay on the happy path.
class FakeUrlLauncher implements LinkLauncher {
  FakeUrlLauncher();

  /// Every URI passed to [launch], in call order.
  final List<Uri> launched = <Uri>[];

  /// The most recent launched URI, or null if none yet — convenience for
  /// the common "assert the last hand-off" check.
  Uri? get lastLaunched => launched.isEmpty ? null : launched.last;

  @override
  Future<bool> launch(Uri url) async {
    launched.add(url);
    return true;
  }
}

/// `OnboardingCompleted` override that reports the welcome carousel as
/// already finished, so the production router's onboarding gate
/// (BUILD_SPEC.md §5.11) doesn't bounce `/` to `/onboarding` in tests.
class _AlreadyOnboarded extends OnboardingCompleted {
  @override
  bool build() => true;
}

/// Pump the full [HoldcloseApp] wired for an integration flow and
/// return the backing [ProviderContainer] so the test can read providers
/// and seed through them (TASKS.md Phase 15.1).
///
/// Default overrides:
/// - [FakeLLMProvider] for the decoder + chat + catch-me-up streams,
/// - [FakeAuthProvider] (auto-signed-in as Sarah Henderson, Mary's
///   primary caregiver, when [demoMode] is true) so the shell lands on
///   Home instead of the sign-in gate,
/// - an in-memory drift database shared by [storageProvider], the
///   medication repository, and the appointment repository so a single
///   seed populates every dashboard surface,
/// - a fixed [clock] (defaults to [kHarnessClock]) on every overridable
///   clock provider — Home greeting, quiet-hours/night-theme, TTS mute,
///   dose-log "today", and appointment "now",
/// - the silent [NoopTTSProvider] + [NoopAnalyticsProvider],
/// - a [FakeUrlLauncher] capturing outbound links.
///
/// [extraOverrides] are appended last so a test can replace any default.
/// [initialLocation] navigates the production router after the first
/// settle (the production router always boots at `/`, so a non-root start
/// is reached with a `go`). The in-memory DB, the fake auth controller,
/// and the container are all torn down via [addTearDown].
Future<ProviderContainer> pumpHoldcloseApp(
  WidgetTester tester, {
  DateTime? clock,
  List<Override>? extraOverrides,
  String initialLocation = '/',
  bool demoMode = true,
}) async {
  // Catch-me-up + any setting that round-trips shared_preferences needs a
  // mock store in the test process; without it the first prefs read
  // throws a MissingPluginException once a flow seeds activity.
  SharedPreferences.setMockInitialValues(<String, Object>{});

  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final DateTime now = clock ?? kHarnessClock;
  DateTime fixedClock() => now;

  // One in-memory drift DB backs the medication + appointment
  // repositories, whose reads are Future-based (no live drift stream to
  // leak a teardown timer). [HoldcloseDatabase.testInstance] wraps a
  // fresh `NativeDatabase.memory()` so each pump gets an isolated DB; the
  // teardown closes the connection before the next test (Phase 15.2).
  final HoldcloseDatabase db = HoldcloseDatabase.testInstance();
  addTearDown(db.close);

  // The journal/patient/settings seam uses the Map-backed fake rather than
  // `DriftStorageProvider`: the latter's `query.watch()` stream schedules a
  // zero-duration "mark closed" timer when it's cancelled during unmount,
  // which trips flutter_test's "Timer still pending" invariant. The fake's
  // plain StreamController has no such teardown artifact — the same reason
  // the Home widget tests pump over `InMemoryStorageProvider`. Its window
  // math reads the pinned clock so a seeded "yesterday" entry stays inside
  // the 30-day watch window deterministically.
  final InMemoryStorageProvider storage =
      InMemoryStorageProvider(clock: fixedClock);
  addTearDown(storage.dispose);

  // The loved-one setup gate (new-user wizard) funnels an authed
  // caregiver with no [Patient] on file to `/setup`. In demo mode the
  // app boots as Mary's caregiver — production's `main.dart` backfills
  // her profile before the first frame — so mirror that here: seed Mary
  // BEFORE the pump so the gate is satisfied and the shell lands on Home,
  // not the wizard. Flows that need the full profile still re-seed via
  // [seedMaryHenderson]; this upsert is idempotent with that.
  if (demoMode) {
    await storage.upsertPatient(maryHenderson());
  }

  final MedicationRepository medicationRepository =
      MedicationRepository(db, clock: fixedClock);
  final AppointmentRepository appointmentRepository =
      AppointmentRepository(db, clock: fixedClock);
  // The appointment list/detail screens + the Home "Next Appointment"
  // card resolve provider names through the appointment repo's reads,
  // while the appointment form writes new providers through the separate
  // [ProviderRepository] seam. Both must point at the SAME in-memory db
  // or an inline-added provider would land in a different store than the
  // one the list reads back from. Production wires its own
  // `HoldcloseDatabase.open()` handle here; in the harness we share the
  // one in-memory db so provider names round-trip (Phase 15.7).
  final ProviderRepository providerRepository = ProviderRepository(db);

  // The chat surface reads the user's data for context on every turn via
  // `gatherChatContext`, which resolves the care-plan + health-log repos in
  // addition to storage/medication/appointment. Point those last two seams
  // at the same in-memory db too — otherwise they fall through to
  // `HoldcloseDatabase.open()` (real on-device SQLite) and throw inside the
  // test zone the moment a flow sends a chat message (Phase 15.8).
  final CarePlanRepository carePlanRepository = CarePlanRepository(db);
  final HealthLogRepository healthLogRepository = HealthLogRepository(db);
  // The patient-timeline merger (Schedule card, Catch-me-up) now also
  // projects standalone care tasks (2026-06-06 unified task/routine model).
  // Its backend opens `HoldcloseDatabase.open()` — real on-device SQLite —
  // so without this override the whole merger future throws in the test zone
  // and the Schedule card falls into its error state instead of rendering
  // the seeded appointments.
  final CareTasksRepository careTasksRepository = CareTasksRepository(db);

  final FakeAuthProvider auth = FakeAuthProvider();
  addTearDown(auth.dispose);
  if (demoMode) {
    // FakeAuthProvider boots signed-out; flip it to signed-in so the
    // router's auth gate (BUILD_SPEC.md §5.12) admits the shell. The
    // stream replays the current state on subscribe, so the redirect sees
    // signed-in on its first evaluation after pumpAndSettle.
    await auth.signInWithGoogle();
  }

  final FakeUrlLauncher urlLauncher = FakeUrlLauncher();

  final List<Override> overrides = <Override>[
    storageBackendProvider.overrideWithValue(storage),
    medicationRepositoryBackendProvider.overrideWithValue(medicationRepository),
    appointmentRepositoryBackendProvider
        .overrideWithValue(appointmentRepository),
    providerRepositoryBackendProvider.overrideWithValue(providerRepository),
    carePlanRepositoryBackendProvider.overrideWithValue(carePlanRepository),
    healthLogRepositoryBackendProvider.overrideWithValue(healthLogRepository),
    careTasksRepositoryBackendProvider.overrideWithValue(careTasksRepository),
    authBackendProvider.overrideWithValue(auth),
    onboardingCompletedProvider.overrideWith(_AlreadyOnboarded.new),
    llmProvider.overrideWithValue(const FakeLLMProvider()),
    ttsProvider.overrideWithValue(const NoopTTSProvider()),
    analyticsBackendProvider.overrideWithValue(const NoopAnalyticsProvider()),
    linkLauncherProvider.overrideWithValue(urlLauncher),
    homeClockProvider.overrideWithValue(fixedClock),
    quietHoursClockProvider.overrideWithValue(fixedClock),
    ttsClockProvider.overrideWithValue(fixedClock),
    doseLogClockProvider.overrideWithValue(fixedClock),
    appointmentListClockProvider.overrideWithValue(fixedClock),
    ...?extraOverrides,
  ];

  // A controlled ProviderScope (not an uncontrolled one) so the scope
  // disposes its container when the widget tree unmounts at end of test —
  // that cancels the keepAlive Timer.periodic the night-theme /
  // quiet-hours providers start, which would otherwise trip the
  // "Timer still pending" invariant before any addTearDown runs.
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const HoldcloseApp(),
    ),
  );
  await tester.pumpAndSettle();

  // Hand the test the live container so its seeders write through the
  // same overrides the running widgets read.
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(HoldcloseApp)),
    listen: false,
  );

  // The loved-one setup gate's provider resolves `getPatient()`
  // asynchronously; its first value is optimistic-false, so the very
  // first redirect can transiently target `/setup` before the resolve
  // lands. Production avoids the flash by populating storage before the
  // first frame (`main.dart` awaits the demo seed); mirror that
  // determinism here by forcing the resolve + a re-settle so the shell
  // is on its final route (Home, since Mary is seeded above) before the
  // test drives it.
  await container.read(patientConfiguredProvider.notifier).reload();
  await tester.pumpAndSettle();

  if (initialLocation != '/') {
    container.read(holdcloseRouterProvider).go(initialLocation);
    await tester.pumpAndSettle();
  }

  return container;
}

/// Seed Mary Henderson's profile (BUILD_SPEC.md §9.1) into the harness's
/// in-memory drift via the existing `lib/seed/mary_henderson.dart`
/// seeder. Backs the Emergency Card + crisis-contact surfaces.
Future<void> seedMaryHenderson(ProviderContainer container) async {
  await container.read(storageProvider).upsertPatient(maryHenderson());
}

/// Surgically populate the Home "Today" dashboard (BUILD_SPEC.md §5.18)
/// for a flow test.
///
/// - [unloggedDoses] + [loggedDoses] create a single daily medication
///   whose schedule fires that many times on the pinned "today"; the
///   first [loggedDoses] occurrences get a `taken` [DoseLog] so the
///   Medications Today card reads "N of M".
/// - [hasAppointment] books one upcoming visit two hours after the
///   pinned clock so the Next Appointment card resolves.
/// - [hasJournalEntry] inserts the most recent demo journal entry so the
///   Recent Activity card has a row.
Future<void> seedDashboard(
  ProviderContainer container, {
  int unloggedDoses = 0,
  int loggedDoses = 0,
  bool hasAppointment = false,
  bool hasJournalEntry = false,
}) async {
  final DateTime now = container.read(homeClockProvider)();

  final int totalDoses = unloggedDoses + loggedDoses;
  if (totalDoses > 0) {
    final MedicationRepository meds =
        container.read(medicationRepositoryBackendProvider);
    const Medication medication = Medication(
      id: 'dash-med-donepezil',
      name: 'Donepezil',
      dosage: '10 mg',
      route: MedicationRoute.oral,
    );
    await meds.upsertMedication(medication);

    // After the v14 windows pivot, seed one window per dose so each
    // (window, entry) pair produces a distinct occurrence — the
    // logged/unlogged split is still unambiguous because the wall-clock
    // anchor varies per window.
    final List<TimeOfDay> times = <TimeOfDay>[
      for (int i = 0; i < totalDoses; i++) TimeOfDay(hour: 7 + i, minute: 0),
    ];
    for (int i = 0; i < times.length; i++) {
      final TimeOfDay tod = times[i];
      final DoseWindow window = DoseWindow(
        id: 'dash-window-$i',
        patientId: 'demo-patient-mary',
        label: 'Slot $i',
        anchorTime: tod,
        sortOrder: i,
      );
      await meds.upsertWindow(window);
      await meds.upsertEntry(MedicationWindowEntry(
        id: 'dash-entry-$i',
        medicationId: medication.id,
        windowId: window.id,
        daysOfWeek: const <int>{},
        startsOn: DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 30)),
      ));
    }

    for (int i = 0; i < loggedDoses; i++) {
      final TimeOfDay tod = times[i];
      final DateTime scheduledFor =
          DateTime(now.year, now.month, now.day, tod.hour, tod.minute);
      await meds.upsertDoseLog(DoseLog(
        id: 'dash-log-$i',
        medicationId: medication.id,
        scheduledFor: scheduledFor,
        takenAt: scheduledFor,
        status: DoseStatus.taken,
      ));
    }
  }

  if (hasAppointment) {
    final AppointmentRepository appts =
        container.read(appointmentRepositoryBackendProvider);
    await appts.upsertAppointment(Appointment(
      id: 'dash-appt-1',
      providerId: 'dash-provider-1',
      startsAt: now.add(const Duration(hours: 2)),
      durationMinutes: 30,
      location: 'Marin Neurology',
      agenda: const <String>[],
      status: AppointmentStatus.upcoming,
    ));
  }

  if (hasJournalEntry) {
    final JournalEntry entry = sampleJournalEntries(clock: () => now).first;
    await container.read(storageProvider).insertJournalEntry(entry);
  }
}

// ---------------------------------------------------------------------------
// Shared finders
// ---------------------------------------------------------------------------

/// The Home dashboard greeting line ("Good morning, Sarah").
final Finder homeGreeting = find.byKey(HomeScreen.greetingKey);

/// The bottom-bar tab whose word label is [label] (e.g. `Care`, `Chat`).
/// Scoped to the [NavigationBar] so it never matches a hub tile or screen
/// body that happens to repeat the word. After the 2026-06-06 IA refactor
/// the bar is four tabs — `Home · Care · Chat · Community` — with the old
/// Team tab folded into Care as a gated Care Circle hub.
Finder tabFor(String label) => find.descendant(
      of: find.byType(TabScaffoldBar),
      matching: find.text(label),
    );

/// Home → Care tab → Care Circle hub tile → [CareTeamHubScreen].
///
/// The Care Circle tile is always shown on the Care hub now (UIUX_REVIEW) —
/// the door to inviting family stays discoverable regardless of the
/// `teamCoordinationEnabled` setting. When coordination is off the hub greets
/// a first-time caregiver with the "Caring with others?" onboarding CTA; the
/// harness's default settings (`AppSettings.defaults()`) ship coordination
/// true, so the sub-hub renders its populated tile grid.
Future<void> openCareCircle(WidgetTester tester) async {
  await tester.tap(tabFor('Care'));
  await tester.pumpAndSettle();
  // The Care Circle tile is last in the grid; scroll it into view before
  // tapping (the grid grew as tiles were added).
  await tester.ensureVisible(findHubTile('Care Circle'));
  await tester.pumpAndSettle();
  await tester.tap(findHubTile('Care Circle'));
  await tester.pumpAndSettle();
  expect(find.byType(CareTeamHubScreen), findsOneWidget);
}

/// The breadcrumb crumb that navigates back to [label] (e.g.
/// `pathHeaderBackTo('Medical')` → the tappable `Medical` crumb in the
/// [PathHeader] trail). The separate "Back to X" control was removed as
/// redundant with the breadcrumb, so the parent crumb is the back
/// affordance now.
Finder pathHeaderBackTo(String label) =>
    find.widgetWithText(InkWell, label);

/// The hub tile whose primary label is [label] (e.g. `Medications`,
/// `People`) on the Care or Care Circle tile hub.
Finder findHubTile(String label) => find.widgetWithText(HubTile, label);

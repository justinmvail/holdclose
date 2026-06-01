/// Shared harness for every Phase 15 `test/integration/*_flow_test.dart`
/// (TASKS.md Phase 15.1). Pumps the full [CareblazersApp] over fake
/// backends, an in-memory drift database, and a pinned clock so flows
/// assert real navigation + persistence without a device, a live LLM, or
/// the on-disk SQLite file.
///
/// Every flow test calls [pumpCareblazersApp] first, optionally seeds via
/// [seedMaryHenderson] / [seedDashboard], then drives the UI with the
/// shared finders ([homeGreeting], [tabFor], [pathHeaderBackTo],
/// [findHubTile]). URL hand-offs are captured by [FakeUrlLauncher] so
/// outbound-link assertions never fire a platform plugin.
library;

import 'package:careblazers/app.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/analytics_provider.dart';
import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/providers/home_clock_provider.dart';
import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/providers/onboarding_provider.dart';
import 'package:careblazers/providers/quiet_hours_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/appointment/appointment_list_screen.dart'
    show appointmentListClockProvider;
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart'
    show doseLogClockProvider;
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/seed/sample_journal.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/widgets/hub_tile.dart';
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

/// Pump the full [CareblazersApp] wired for an integration flow and
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
Future<ProviderContainer> pumpCareblazersApp(
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
  // leak a teardown timer). [CareblazersDatabase.testInstance] wraps a
  // fresh `NativeDatabase.memory()` so each pump gets an isolated DB; the
  // teardown closes the connection before the next test (Phase 15.2).
  final CareblazersDatabase db = CareblazersDatabase.testInstance();
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

  final MedicationRepository medicationRepository =
      MedicationRepository(db, clock: fixedClock);
  final AppointmentRepository appointmentRepository =
      AppointmentRepository(db, clock: fixedClock);

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
      child: const CareblazersApp(),
    ),
  );
  await tester.pumpAndSettle();

  // Hand the test the live container so its seeders write through the
  // same overrides the running widgets read.
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(CareblazersApp)),
    listen: false,
  );

  if (initialLocation != '/') {
    container.read(careblazersRouterProvider).go(initialLocation);
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

    // Distinct times across the morning so each occurrence is its own
    // ScheduledDose and the logged/unlogged split is unambiguous.
    final List<TimeOfDay> times = <TimeOfDay>[
      for (int i = 0; i < totalDoses; i++) TimeOfDay(hour: 7 + i, minute: 0),
    ];
    await meds.upsertSchedule(DoseSchedule(
      id: 'dash-sched-donepezil',
      medicationId: medication.id,
      frequencyKind: FrequencyKind.daily,
      timesOfDay: times,
      daysOfWeek: const <int>{},
      startsOn: DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 30)),
    ));

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

/// The bottom-bar tab whose word label is [label] (e.g. `Medical`,
/// `Team`). Scoped to the [NavigationBar] so it never matches a hub
/// tile or screen body that happens to repeat the word.
Finder tabFor(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

/// The [PathHeader] word-labeled Back control that returns to [label]
/// (e.g. `pathHeaderBackTo('Medical')` → the "Back to Medical" chip).
Finder pathHeaderBackTo(String label) => find.text('Back to $label');

/// The hub tile whose primary label is [label] (e.g. `Medications`,
/// `Calendar`) on a Medical / Care Team tile hub.
Finder findHubTile(String label) => find.widgetWithText(HubTile, label);

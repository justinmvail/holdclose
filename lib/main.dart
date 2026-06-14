import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'models/settings.dart';
import 'providers/active_patient_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/care_events_provider.dart';
import 'providers/care_shifts_provider.dart';
import 'providers/care_tasks_provider.dart';
import 'providers/expenses_provider.dart';
import 'providers/local_notifications_provider.dart';
import 'providers/notifications_provider.dart';
import 'providers/onboarding_provider.dart';
import 'providers/patient_configured_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/storage_provider.dart';
import 'providers/tts_provider.dart';
import 'seed/demo_dataset.dart';
import 'services/log_buffer.dart';
import 'services/seed_repository.dart';
import 'services/sync_service.dart';

/// Build-time switch for the comprehensive test-data seed
/// (`--dart-define=SEED_DEMO=true`). Off by default — only the
/// `tools/seed_demo.sh` builds set it. Distinct from `DEMO_MODE` (the pitch
/// demo's reset-to-Mary), so a normal build never wipes a tester's data.
const bool _seedDemoEnabled = bool.fromEnvironment('SEED_DEMO');

/// A unique token the seeding script stamps into each build
/// (`--dart-define=SEED_TOKEN=<ts>`). The seed runs once per distinct token —
/// it's stored after a successful seed, so the same installed build never
/// re-wipes on subsequent cold launches. Rerun the script (fresh token) to
/// get a fresh dataset.
const String _seedDemoToken = String.fromEnvironment('SEED_TOKEN');

/// SharedPreferences key holding the last [_seedDemoToken] that was applied.
const String seedDemoTokenPrefsKey = 'careblazers.seed_demo_token';

/// SharedPreferences flag marking the one-time multi-patient care-circle
/// re-stamp ([maybeRestampCareCirclePatient]) as done, so it runs at most
/// once per install (Issue #6).
const String careCircleRestampPrefsKey =
    'careblazers.care_circle_restamp_done';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Tee on-device logs into a small ring buffer so a bug report can carry
  // recent context (what happened right before the report), not just a
  // screenshot. Console output is preserved — we wrap, never replace. The
  // buffer is only ever READ when a report is sent.
  _captureLogs();

  // Preload the persisted onboarding-complete flag BEFORE the first frame
  // so a returning caregiver's router decision is correct on frame zero —
  // no welcome-carousel flash (alpha bug: "intro screen shows on every
  // launch", which was the in-memory-only flag resetting each launch).
  final bool onboardingDone = await readOnboardingCompleted();

  // Restore the persisted Google session (alpha builds) so a returning
  // Google tester boots straight to Home — no sign-in-screen flash, no
  // re-tap. Null in non-alpha builds / first launch / signed out; only
  // authBackend's alpha branch reads it. A stale LOCAL identity is never
  // restored here (the local bypass was removed) — such testers land on
  // sign-in and use Google.
  preloadedAlphaUser = await readPersistedAlphaUser();

  final ProviderContainer container = ProviderContainer(
    // BUILD_SPEC.md §5.10 + §6.3 — pipe the SettingsNotifier through
    // the TTS selector's settings input. A settings change INVALIDATES
    // the keepAlive tts provider so its next read re-resolves; crossing
    // a quiet-hours boundary with no settings change is covered by the
    // minute-polling QuietHoursActive tick the selector also watches.
    overrides: <Override>[
      ttsSettingsProvider.overrideWith(
        (Ref ref) => ref.watch(settingsProvider),
      ),
      // BUILD_SPEC.md Phase 12.8 — drop the platform-bound notifier in
      // for real builds. Widget tests + integration tour leave the
      // default `NoopNotificationsProvider` so they don't transitively
      // pull `flutter_local_notifications` into the test harness.
      notificationsBackendProvider
          .overrideWithValue(LocalNotificationsProvider()),
      // Seed the persisted onboarding flag so the carousel is skipped on
      // return launches without a frame-zero flash.
      onboardingInitialProvider.overrideWithValue(onboardingDone),
    ],
  );

  // BUILD_SPEC.md §9.3 + Task 26 — demo-mode reset-on-launch hook.
  // Runs before the first frame so the seed is in place by the time
  // the journal stream watch fires, and screens never see the pre-
  // reset state flash through.
  await maybeResetForDemo(container, demoMode: demoModeEnabled);

  // Comprehensive test-data seed (tools/seed_demo.sh). One-shot per build:
  // wipes the database and lays down six months of every data type, guarded
  // by a token so it seeds exactly once per script run and then leaves the
  // tester's edits alone on later launches.
  await maybeSeedDemoDataset(container);

  // Preload "is a loved one on file" AFTER any demo reset/seed and BEFORE
  // the first frame, so a set-up caregiver's frame-zero router decision is
  // Home — not a /setup flash while the async SQLite read resolves. Same
  // preload pattern as the onboarding flag + alpha user above.
  try {
    preloadedPatientConfigured =
        await container.read(storageProvider).getPatient() != null;
  } catch (_) {
    preloadedPatientConfigured = null; // resolve async, as before
  }

  // One-time multi-patient re-stamp (Issue #6): move any care-circle row
  // still stamped with the legacy hardcoded `demo-patient-mary` id onto the
  // ACTIVE loved one, so a real alpha user with more than one person on file
  // (e.g. left over from the earlier duplicate-patient bug) stops seeing
  // another person's tasks / shifts / expenses / notes. Runs AFTER the
  // patient is resolved above and is guarded to run once per install.
  // Fail-safe — swallows its own errors so a launch is never blocked.
  await maybeRestampCareCirclePatient(container);

  // Server-authoritative sync: kick the engine AFTER the first frame so
  // launch is never blocked on the network. The lifecycle observer also
  // re-syncs on resume + drives the foreground poll. Entirely fail-safe —
  // every step no-ops when there's no active circle (and bootstrapCircle
  // swallows its own errors), so a local-only / offline install boots
  // exactly as it does today.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_bootstrapSync(container));
  });
  WidgetsBinding.instance.addObserver(_SyncLifecycleObserver(container));

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CareblazersApp(),
    ),
  );
}

/// Tee `debugPrint`, framework errors, and uncaught async errors into
/// [LogBuffer] (for bug reports) while preserving the normal handlers.
void _captureLogs() {
  final originalPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message.isNotEmpty) {
      LogBuffer.instance.add(message);
    }
    originalPrint(message, wrapWidth: wrapWidth);
  };

  final priorFlutterOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    LogBuffer.instance.add('FlutterError: ${details.exceptionAsString()}');
    (priorFlutterOnError ?? FlutterError.presentError)(details);
  };

  final priorPlatformOnError =
      WidgetsBinding.instance.platformDispatcher.onError;
  WidgetsBinding.instance.platformDispatcher.onError =
      (Object error, StackTrace stack) {
    LogBuffer.instance.add('Uncaught: $error');
    return priorPlatformOnError?.call(error, stack) ?? false;
  };
}

/// Resolve the active circle, then push+pull once and start the
/// foreground poll (server-authoritative sync). Fire-and-forget from a
/// post-first-frame callback; never awaited before [runApp].
Future<void> _bootstrapSync(ProviderContainer container) async {
  try {
    final SyncController sync = container.read(syncControllerProvider);
    await sync.bootstrapCircle();
    sync.startInterval();
    await sync.syncNow();
    // After the circle is bound, optionally force-push EVERY local row up
    // (tools/seed_demo.sh data is written before the circle exists, so it
    // never auto-syncs). One-shot per token.
    await maybeResyncAll(container, sync);
    // A returning caregiver on a fresh install has their loved one on the
    // backend, not yet on this device — the adopt + pull above just brought
    // them down. Refresh the setup gate so the redirect opens to Home
    // instead of stranding them on the (now-stale) /setup wizard. Cheap +
    // safe for every launch: a no-op re-read of `getPatient()`.
    await container.read(patientConfiguredProvider.notifier).reload();
  } catch (e) {
    // Sync is additive — a failure here must never affect the app. The
    // breadcrumb lands in LogBuffer for feedback reports.
    debugPrint('sync: bootstrap failed: $e');
  }
}

/// Build-time switch to force a full local→backend resync once
/// (`--dart-define=RESYNC_ALL=true --dart-define=RESYNC_TOKEN=<ts>`). Pushes
/// everything on the device up to the bound circle's backend — used to get
/// seed data (written before the circle existed) onto the server so a circle
/// member can pull it. Runs once per distinct token.
const bool _resyncAllEnabled = bool.fromEnvironment('RESYNC_ALL');
const String _resyncAllToken = String.fromEnvironment('RESYNC_TOKEN');
const String resyncAllTokenPrefsKey = 'careblazers.resync_all_token';

@visibleForTesting
Future<bool> maybeResyncAll(
  ProviderContainer container,
  SyncController sync, {
  Future<SharedPreferences> Function()? prefs,
}) async {
  if (!_resyncAllEnabled || _resyncAllToken.isEmpty) return false;
  final SharedPreferences store =
      await (prefs ?? SharedPreferences.getInstance)();
  if (store.getString(resyncAllTokenPrefsKey) == _resyncAllToken) return false;
  await sync.resyncAllLocal();
  await store.setString(resyncAllTokenPrefsKey, _resyncAllToken);
  return true;
}

/// Re-runs a sync on `AppLifecycleState.resumed` so a phone returning to
/// the foreground pushes anything queued while backgrounded and pulls
/// fresh changes (server-authoritative sync).
class _SyncLifecycleObserver extends WidgetsBindingObserver {
  _SyncLifecycleObserver(this._container);

  final ProviderContainer _container;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      try {
        _container.read(syncControllerProvider).onAppResumed();
      } catch (_) {
        // Never let a lifecycle callback throw.
      }
    }
  }
}

/// Demo-mode reset-on-launch wiring (BUILD_SPEC.md §9.3 + Task 26).
///
/// When [demoMode] is true AND the persisted [AppSettings] has
/// `resetOnLaunchDemo` set, wipes local storage via
/// [StorageProvider.reset] then re-seeds Mary Henderson + the demo
/// journal entries via [SeedRepository.populateAll] so the pitch demo
/// boots into a known-clean state. When `resetOnLaunchDemo` is off, the
/// caregiver's data is left intact but Mary's profile is still
/// backfilled if missing ([SeedRepository.ensurePatient]) so the demo
/// always boots as her caregiver. No-op for real-mode builds (the
/// `DEMO_MODE` define is absent).
///
/// Pure of side effects on the widget tree — accepts a
/// [ProviderContainer] so the bootstrap can run before [runApp] and
/// share the same backend instances the widget tree later sees through
/// [UncontrolledProviderScope]. Exposed for tests via
/// [visibleForTesting]; production callers go through [main].
@visibleForTesting
Future<void> maybeResetForDemo(
  ProviderContainer container, {
  required bool demoMode,
}) async {
  if (!demoMode) return;
  final StorageProvider storage = container.read(storageProvider);
  final AppSettings settings = await storage.getSettings();
  if (settings.resetOnLaunchDemo) {
    await storage.reset();
    await container.read(seedRepositoryProvider).populateAll();
    return;
  }
  // Reset-on-launch is off (the caregiver is iterating on real data),
  // but the demo must still boot as Mary's caregiver — backfill her
  // profile if no loved one is on file yet so patient-dependent screens
  // (Emergency Card, the Medical header) aren't empty. Idempotent and
  // non-destructive: a no-op once Mary exists, and it never touches
  // journal or medication data.
  await container.read(seedRepositoryProvider).ensurePatient();
}

/// Comprehensive test-data seed wiring (`tools/seed_demo.sh`).
///
/// When [_seedDemoEnabled] is set AND a non-empty [_seedDemoToken] is baked
/// in that DIFFERS from the last-applied token in SharedPreferences, this
/// wipes the whole database and lays down six months of realistic data across
/// every data type (see [seedDemoDataset]), then records the token so it
/// never re-runs for this build. A no-op when the flag/token is absent or the
/// token has already been applied — so a tester's own edits survive relaunch.
/// Returns true when a seed actually ran. Runs before [runApp] so screens
/// render against the seeded data on frame zero.
@visibleForTesting
Future<bool> maybeSeedDemoDataset(
  ProviderContainer container, {
  Future<SharedPreferences> Function()? prefs,
  DateTime Function()? clock,
}) async {
  if (!_seedDemoEnabled || _seedDemoToken.isEmpty) return false;
  final SharedPreferences store =
      await (prefs ?? SharedPreferences.getInstance)();
  if (store.getString(seedDemoTokenPrefsKey) == _seedDemoToken) return false;

  final StorageProvider storage = container.read(storageProvider);
  await storage.reset();
  await seedDemoDataset(container, clock: clock);
  await store.setString(seedDemoTokenPrefsKey, _seedDemoToken);
  return true;
}

/// One-time re-stamp of legacy care-circle rows onto the active loved one
/// (multi-patient, Issue #6).
///
/// Background: before the display-scoping fix, the care-circle features
/// (Tasks / Shifts / Expenses) and the calendar notes stamped every new row
/// with a hardcoded `demo-patient-mary` const, and the boards read EVERY
/// row unfiltered. An alpha user who ended up with more than one loved one
/// on file (e.g. from the earlier duplicate-patient bug) therefore saw
/// another person's data on the now patient-scoped boards — the legacy rows
/// are stranded under `demo-patient-mary` while the active patient is some
/// other id.
///
/// This walks the four care-circle tables and re-files any row stamped with
/// [fallbackPatientId] ('demo-patient-mary') under the current active
/// patient id, so the previously-hidden data reappears under the right
/// person. Guarded by [careCircleRestampPrefsKey] so it runs at most once
/// per install. The single-patient product model makes this safe — there's
/// exactly one loved one the rows can belong to.
///
/// Edge cases handled:
///  * **No patient on file yet** (fresh install) → no-op, and the guard is
///    NOT set, so the re-stamp gets a real chance once a loved one exists.
///  * **Active patient IS the legacy id** (the common single-install / demo
///    case) → every `restampPatient` call is a `from == to` no-op; the guard
///    is set so we don't re-scan on every launch.
///  * The re-stamp re-emits each moved row through the sync sink — that's
///    acceptable; the server resolves it last-write-wins (and the sink is a
///    no-op anyway when no circle is bound).
///
/// Fail-safe: every step swallows its own errors so a launch is never
/// blocked. Returns true when the re-stamp actually ran to completion (the
/// guard was set), false when it was skipped (already done, or no patient).
@visibleForTesting
Future<bool> maybeRestampCareCirclePatient(
  ProviderContainer container, {
  Future<SharedPreferences> Function()? prefs,
}) async {
  try {
    final SharedPreferences store =
        await (prefs ?? SharedPreferences.getInstance)();
    if (store.getBool(careCircleRestampPrefsKey) ?? false) return false;

    // Resolve the active loved one. With no patient on file yet, hold off —
    // don't burn the one-shot guard before there's a target to re-file onto.
    final String activeId =
        await container.read(activePatientIdProvider.future);
    final bool hasPatient =
        await container.read(storageProvider).getPatient() != null;
    if (!hasPatient) return false;

    // Re-file each table's legacy rows onto the active patient. Each call is
    // a no-op when activeId == fallbackPatientId (the single-install case).
    await container
        .read(careTasksRepositoryProvider)
        .restampPatient(fallbackPatientId, activeId);
    await container
        .read(careShiftsRepositoryProvider)
        .restampPatient(fallbackPatientId, activeId);
    await container
        .read(expensesRepositoryProvider)
        .restampPatient(fallbackPatientId, activeId);
    await container
        .read(careEventsRepositoryProvider)
        .restampPatient(fallbackPatientId, activeId);

    await store.setBool(careCircleRestampPrefsKey, true);
    return true;
  } catch (e) {
    // Additive + best-effort — a failure must never affect launch. The
    // breadcrumb lands in LogBuffer for feedback reports; the guard stays
    // unset so the next launch retries.
    debugPrint('migration: care-circle patient re-stamp failed: $e');
    return false;
  }
}

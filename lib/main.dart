import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'app.dart';
import 'models/settings.dart';
import 'providers/auth_provider.dart';
import 'providers/local_notifications_provider.dart';
import 'providers/notifications_provider.dart';
import 'providers/onboarding_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/storage_provider.dart';
import 'providers/tts_provider.dart';
import 'services/seed_repository.dart';
import 'services/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
    // the TTS selector's settings input so toggling "Read scripts
    // aloud" off (or hitting quiet hours) re-resolves
    // `ref.read(ttsProvider)` to `NoopTTSProvider` on the next read.
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

/// Resolve the active circle, then push+pull once and start the
/// foreground poll (server-authoritative sync). Fire-and-forget from a
/// post-first-frame callback; never awaited before [runApp].
Future<void> _bootstrapSync(ProviderContainer container) async {
  try {
    final SyncController sync = container.read(syncControllerProvider);
    await sync.bootstrapCircle();
    sync.startInterval();
    await sync.syncNow();
  } catch (_) {
    // Sync is additive — a failure here must never affect the app.
  }
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

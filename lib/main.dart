import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'app.dart';
import 'models/settings.dart';
import 'providers/settings_provider.dart';
import 'providers/storage_provider.dart';
import 'providers/tts_provider.dart';
import 'services/seed_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final ProviderContainer container = ProviderContainer(
    // BUILD_SPEC.md §5.10 + §6.3 — pipe the SettingsNotifier through
    // the TTS selector's settings input so toggling "Read scripts
    // aloud" off (or hitting quiet hours) re-resolves
    // `ref.read(ttsProvider)` to `NoopTTSProvider` on the next read.
    overrides: <Override>[
      ttsSettingsProvider.overrideWith(
        (Ref ref) => ref.watch(settingsProvider),
      ),
    ],
  );

  // BUILD_SPEC.md §9.3 + Task 26 — demo-mode reset-on-launch hook.
  // Runs before the first frame so the seed is in place by the time
  // the journal stream watch fires, and screens never see the pre-
  // reset state flash through.
  await maybeResetForDemo(container, demoMode: demoModeEnabled);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CareblazersApp(),
    ),
  );
}

/// Demo-mode reset-on-launch wiring (BUILD_SPEC.md §9.3 + Task 26).
///
/// When [demoMode] is true AND the persisted [AppSettings] has
/// `resetOnLaunchDemo` set, wipes local storage via
/// [StorageProvider.reset] then re-seeds Mary Henderson + the demo
/// journal entries via [SeedRepository.populateAll] so the pitch demo
/// boots into a known-clean state. No-op for real-mode builds (the
/// `DEMO_MODE` define is absent) or when the caregiver has flipped the
/// Settings → Demo mode toggle off.
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
  if (!settings.resetOnLaunchDemo) return;
  await storage.reset();
  await container.read(seedRepositoryProvider).populateAll();
}

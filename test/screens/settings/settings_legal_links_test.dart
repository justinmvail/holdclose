import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/providers/link_launcher_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/tts_provider.dart';
import 'package:holdclose/screens/settings/settings_screen.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../../integration/test_harness.dart' show FakeUrlLauncher;

/// Privacy + Terms must be reachable from Settings, not only from the sign-in
/// screen a caregiver saw once during onboarding.
///
/// Before these rows existed, a caregiver who wanted to check what the app
/// collects and who can see it had no way to find out from inside the app.
/// Track 1 Principle 1 asks exactly that: "clear limits on what information is
/// collected, how it is used, and who can see it".
Future<FakeUrlLauncher> _pump(WidgetTester tester) async {
  final FakeUrlLauncher launcher = FakeUrlLauncher();
  await tester.binding.setSurfaceSize(const Size(420, 4200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
      ttsProvider.overrideWith((Ref _) => const NoopTTSProvider()),
      linkLauncherProvider.overrideWithValue(launcher),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pump();
  return launcher;
}

Future<void> _tapRow(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pump();
  await tester.tap(find.byKey(key), warnIfMissed: false);
  await tester.pump();
}

void main() {
  group('Settings → About legal links', () {
    testWidgets('privacy row opens the published privacy page',
        (WidgetTester tester) async {
      final FakeUrlLauncher launcher = await _pump(tester);
      await _tapRow(tester, const Key('settings-privacy'));
      expect(
        launcher.lastLaunched.toString(),
        'https://junocode.studio/holdclose/privacy',
      );
    });

    testWidgets('terms row opens the published terms page',
        (WidgetTester tester) async {
      final FakeUrlLauncher launcher = await _pump(tester);
      await _tapRow(tester, const Key('settings-terms'));
      expect(
        launcher.lastLaunched.toString(),
        'https://junocode.studio/holdclose/terms',
      );
    });
  });
}

import 'package:alchemist/alchemist.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/tts_provider.dart';
import 'package:holdclose/screens/settings/settings_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI golden — Settings screen in its default state with the §5.10
/// non-demo gating: Read scripts aloud + Font size + Appearance +
/// Account + About sections all visible. NoopTTSProvider is wired in
/// so the voice picker resolves to an empty dropdown rather than
/// hitting flutter_tts via the platform channel.
void main() {
  group('SettingsScreen golden', () {
    goldenTest(
      'renders every §5.10 section in the default-light layout',
      fileName: 'settings_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'default (NOT DEMO_MODE — Account visible)',
            child: ProviderScope(
              overrides: <Override>[
                storageBackendProvider
                    .overrideWithValue(InMemoryStorageProvider()),
                ttsProvider
                    .overrideWith((Ref _) => const NoopTTSProvider()),
              ],
              child: SizedBox(
                width: 420,
                height: 1400,
                child: MaterialApp(
                  home: const SettingsScreen(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: holdcloseColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'app.dart';
import 'providers/settings_provider.dart';
import 'providers/tts_provider.dart';

void main() {
  runApp(
    ProviderScope(
      // BUILD_SPEC.md §5.10 + §6.3 — pipe the SettingsNotifier through
      // the TTS selector's settings input so toggling "Read scripts
      // aloud" off (or hitting quiet hours) re-resolves
      // `ref.read(ttsProvider)` to `NoopTTSProvider` on the next read.
      overrides: <Override>[
        ttsSettingsProvider.overrideWith(
          (Ref ref) => ref.watch(settingsProvider),
        ),
      ],
      child: const CareblazersApp(),
    ),
  );
}

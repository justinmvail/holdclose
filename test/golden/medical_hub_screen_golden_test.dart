import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Golden of the populated Care hub — the seven base tiles in their
/// documented order (BUILD_SPEC.md §5.13, TASKS.md Phase 14.15; the hub was
/// renamed "Medical" → "Care" in the 2026-06-06 IA refactor). The gated
/// Care Circle tile is left off (team coordination disabled) so this golden
/// pins the default seven-tile landing.
///
/// [MedicalHubScreen] is now a ConsumerWidget that reads `settingsProvider`,
/// so it's wrapped in a ProviderScope with the storage seam overridden to
/// pin team coordination off. No theme is passed: per
/// `flutter_test_config.dart`, goldens avoid dragging google_fonts through
/// the framework; the hub's [PathHeader] + [HubTile] children re-apply their
/// brand colors directly.
InMemoryStorageProvider _teamOffStorage() {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  storage.updateSettings(
    AppSettings.defaults().copyWith(teamCoordinationEnabled: false),
  );
  return storage;
}

void main() {
  group('MedicalHubScreen golden', () {
    goldenTest(
      'renders the populated 7-tile hub landing',
      fileName: 'medical_hub_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'care hub — 7 tiles (Phase 14.15)',
            child: SizedBox(
              width: 420,
              height: 820,
              child: ProviderScope(
                overrides: <Override>[
                  storageProvider.overrideWithValue(_teamOffStorage()),
                ],
                child: MaterialApp(
                  builder: (BuildContext context, Widget? child) => ColoredBox(
                    color: careblazersColors.background,
                    child: child ?? const SizedBox.shrink(),
                  ),
                  home: const MedicalHubScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

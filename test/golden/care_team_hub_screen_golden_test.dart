import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/team/care_team_hub_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pre-seed a fake storage so [CareTeamHubScreen] hydrates with
/// `teamCoordinationEnabled = true` and the populated tile grid renders
/// — the production default is off and would otherwise paint the
/// "Coordinate care" empty state instead.
InMemoryStorageProvider _seededStorage() {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  storage.updateSettings(
    AppSettings.defaults().copyWith(teamCoordinationEnabled: true),
  );
  return storage;
}

/// Goldens of the Care Team hub in both visual states (BUILD_SPEC.md
/// §5.13, TASKS.md Phase 14.26): the populated 6-tile grid (with the
/// settings opt-in flipped on) and the default "Coordinate care" empty
/// state. No theme is passed: per `flutter_test_config.dart`, goldens
/// avoid dragging google_fonts through the framework; the hub's
/// [PathHeader] + [HubTile] children re-apply their brand colors
/// directly.
void main() {
  group('CareTeamHubScreen golden', () {
    goldenTest(
      'renders the populated 6-tile hub landing',
      fileName: 'care_team_hub_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'care team hub — 6 tiles (Phase 14.26)',
            child: SizedBox(
              width: 420,
              height: 820,
              child: ProviderScope(
                overrides: <Override>[
                  storageProvider.overrideWithValue(_seededStorage()),
                ],
                child: MaterialApp(
                  builder: (BuildContext context, Widget? child) =>
                      ColoredBox(
                    color: careblazersColors.background,
                    child: child ?? const SizedBox.shrink(),
                  ),
                  home: const CareTeamHubScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'renders the "Coordinate care" empty state when coordination is off',
      fileName: 'care_team_hub_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'care team hub — coordination off (default)',
            child: SizedBox(
              width: 420,
              height: 820,
              child: ProviderScope(
                overrides: <Override>[
                  // Override storage even for the default-state golden so
                  // the settings provider doesn't try to open drift
                  // (path_provider is unimplemented in the test host).
                  storageProvider.overrideWithValue(InMemoryStorageProvider()),
                ],
                child: MaterialApp(
                  builder: (BuildContext context, Widget? child) =>
                      ColoredBox(
                    color: careblazersColors.background,
                    child: child ?? const SizedBox.shrink(),
                  ),
                  home: const CareTeamHubScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/team/care_team_hub_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pre-seed a fake storage with an explicit `teamCoordinationEnabled` so
/// each golden pins the state it depicts rather than relying on the model
/// default (which is now on — toggle it off in the empty-state scenario).
InMemoryStorageProvider _storageWith({required bool coordination}) {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  storage.updateSettings(
    AppSettings.defaults().copyWith(teamCoordinationEnabled: coordination),
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
                  storageProvider
                      .overrideWithValue(_storageWith(coordination: true)),
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
                  // Explicitly OFF — the model default is now on, so the
                  // CTA empty state must be pinned here. (Storage is also
                  // overridden so the settings provider doesn't open drift;
                  // path_provider is unimplemented in the test host.)
                  storageProvider
                      .overrideWithValue(_storageWith(coordination: false)),
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

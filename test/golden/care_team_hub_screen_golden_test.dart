import 'package:alchemist/alchemist.dart';
import 'package:careblazers/screens/team/care_team_hub_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden of the populated Care Team hub — all six tiles in their
/// documented order (BUILD_SPEC.md §5.13, TASKS.md Phase 14.26). No theme
/// is passed: per `flutter_test_config.dart`, goldens avoid dragging
/// google_fonts through the framework; the hub's [PathHeader] + [HubTile]
/// children re-apply their brand colors directly.
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
              child: MaterialApp(
                builder: (BuildContext context, Widget? child) => ColoredBox(
                  color: careblazersColors.background,
                  child: child ?? const SizedBox.shrink(),
                ),
                home: const CareTeamHubScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

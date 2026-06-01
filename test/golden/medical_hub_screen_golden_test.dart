import 'package:alchemist/alchemist.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden of the populated Medical hub — all seven tiles in their
/// documented order (BUILD_SPEC.md §5.13, TASKS.md Phase 14.15). No theme
/// is passed: per `flutter_test_config.dart`, goldens avoid dragging
/// google_fonts through the framework; the hub's [PathHeader] + [HubTile]
/// children re-apply their brand colors directly.
void main() {
  group('MedicalHubScreen golden', () {
    goldenTest(
      'renders the populated 7-tile hub landing',
      fileName: 'medical_hub_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'medical hub — 7 tiles (Phase 14.15)',
            child: SizedBox(
              width: 420,
              height: 820,
              child: MaterialApp(
                builder: (BuildContext context, Widget? child) => ColoredBox(
                  color: careblazersColors.background,
                  child: child ?? const SizedBox.shrink(),
                ),
                home: const MedicalHubScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

import 'package:alchemist/alchemist.dart';
import 'package:careblazers/screens/medical/cards_documents_hub_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden of the populated Cards & Documents sub-hub — all three tiles in
/// their documented order (BUILD_SPEC.md §5.13, TASKS.md Phase 14.22). No
/// theme is passed: per `flutter_test_config.dart`, goldens avoid dragging
/// google_fonts through the framework; the hub's [PathHeader] + [HubTile]
/// children re-apply their brand colors directly.
void main() {
  group('CardsDocumentsHubScreen golden', () {
    goldenTest(
      'renders the populated 3-tile cards hub',
      fileName: 'cards_documents_hub_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'cards & documents — 3 tiles (Phase 14.22)',
            child: SizedBox(
              width: 420,
              height: 620,
              child: MaterialApp(
                builder: (BuildContext context, Widget? child) => ColoredBox(
                  color: careblazersColors.background,
                  child: child ?? const SizedBox.shrink(),
                ),
                home: const CardsDocumentsHubScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

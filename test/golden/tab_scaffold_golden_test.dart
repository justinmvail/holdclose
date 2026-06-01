import 'package:alchemist/alchemist.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/tab_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// CI-only golden of the [TabScaffoldBar] in its default state
/// (Home tab selected). Per the alchemist convention only one CI
/// golden lands per widget — `goldens/ci/tab_scaffold_default.png`.
void main() {
  group('TabScaffoldBar golden', () {
    goldenTest(
      'renders the five-tab bar (default state, Home selected)',
      fileName: 'tab_scaffold_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'home selected',
            child: ProviderScope(
              child: Container(
                width: 400,
                color: careblazersColors.background,
                child: TabScaffoldBar(
                  currentIndex: 0,
                  onDestinationSelected: (_) {},
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

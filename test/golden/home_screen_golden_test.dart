import 'package:alchemist/alchemist.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// CI-only golden of [HomeScreen] in its default state — Home tab
/// root, no decoder push in flight. Wrapped in the real router so the
/// AppBar gear and secondary rows render in the same shell they ship
/// in.
///
/// We deliberately pump via the router rather than dropping a bare
/// `HomeScreen` widget so the golden catches regressions in the
/// shell-level layout (back-button suppression on the tab root, gear
/// placement in actions).
void main() {
  group('HomeScreen golden', () {
    goldenTest(
      'renders the primary tap target + secondary rows',
      fileName: 'home_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'default (Home tab root)',
            child: ProviderScope(
              child: SizedBox(
                width: 390,
                height: 780,
                child: MaterialApp.router(
                  routerConfig: buildRouter(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.surfaceWarm,
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

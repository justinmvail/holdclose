import 'package:alchemist/alchemist.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// CI-only golden of [BehaviorPickerScreen] in its default state — the
/// 4×2 grid of canonical behaviors plus the "Something else" pill.
/// Pumped through a minimal router so the AppBar's auto back arrow
/// renders the same way it does when pushed from Home.
void main() {
  group('BehaviorPickerScreen golden', () {
    goldenTest(
      'renders the 4x2 behavior grid + free-text pill',
      fileName: 'behavior_picker_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'default (pushed onto root navigator)',
            child: ProviderScope(
              child: SizedBox(
                width: 390,
                height: 780,
                child: MaterialApp.router(
                  routerConfig: _goldenRouter(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.background,
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

GoRouter _goldenRouter() {
  return GoRouter(
    initialLocation: '/decoder/behavior',
    routes: <RouteBase>[
      GoRoute(
        path: '/decoder/behavior',
        builder: (BuildContext context, GoRouterState state) =>
            const BehaviorPickerScreen(),
      ),
      // Stubbed sink so any accidental tap during golden capture
      // doesn't blow up the test with an unregistered-route error.
      GoRoute(
        path: '/decoder/triage',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
}

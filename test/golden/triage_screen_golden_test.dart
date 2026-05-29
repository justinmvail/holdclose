import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/decoder/triage_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// CI-only golden of [TriageScreen] at its Q1 entry state — behavior
/// chip + "1 of 3" progress + the 5 Q1 pill buttons + disabled
/// "Next →" CTA. Pumped through a minimal router so the AppBar's
/// auto-rendered chrome matches the production push-from-picker path.
void main() {
  group('TriageScreen golden', () {
    goldenTest(
      'renders Q1 with pill buttons and disabled Next CTA',
      fileName: 'triage_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'default (Q1, no selection)',
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
    initialLocation: '/decoder/triage',
    routes: <RouteBase>[
      GoRoute(
        path: '/decoder/triage',
        builder: (BuildContext context, GoRouterState state) =>
            const TriageScreen(
          args: TriageArgs.forBehavior(
            Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅'),
          ),
        ),
      ),
      // Stubbed sink so an accidental forward tap during capture
      // doesn't blow up the test with an unregistered-route error.
      GoRoute(
        path: '/decoder/result',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
}

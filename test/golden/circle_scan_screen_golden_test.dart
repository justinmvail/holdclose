import 'package:alchemist/alchemist.dart';
import 'package:careblazers/screens/team/circle_scan_screen.dart';
import 'package:careblazers/services/fake_forum_api_client.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI golden of the "Scan to add" surface at `/team/circle/scan`.
///
/// [CircleScanScreen.enableCamera] is `false` so mobile_scanner's live
/// camera never starts — the scanner area renders the static placeholder
/// instead (the same seam the widget tests use), keeping the golden fully
/// offline + deterministic.
GoRouter _router() => GoRouter(
      initialLocation: '/team/circle/scan',
      routes: <RouteBase>[
        GoRoute(
          path: '/team/circle',
          builder: (BuildContext c, GoRouterState s) =>
              const Scaffold(body: SizedBox.shrink()),
          routes: <RouteBase>[
            GoRoute(
              path: 'scan',
              builder: (BuildContext c, GoRouterState s) =>
                  const CircleScanScreen(enableCamera: false),
            ),
          ],
        ),
      ],
    );

Widget _host() {
  return ProviderScope(
    overrides: <Override>[
      forumApiClientProvider.overrideWithValue(FakeForumApiClient()),
    ],
    child: SizedBox(
      width: 440,
      height: 1000,
      child: MaterialApp.router(
        routerConfig: _router(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('CircleScanScreen golden', () {
    goldenTest(
      'scan surface — camera-off placeholder',
      fileName: 'circle_scan_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'scanning (camera disabled)',
            child: _host(),
          ),
        ],
      ),
    );
  });
}

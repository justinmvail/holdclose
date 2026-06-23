import 'package:alchemist/alchemist.dart';
import 'package:holdclose/screens/team/username_screen.dart';
import 'package:holdclose/services/fake_forum_api_client.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

Widget _host() {
  final GoRouter router = GoRouter(
    initialLocation: '/team/circle/username',
    routes: <RouteBase>[
      GoRoute(
        path: '/team/circle',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
        routes: <RouteBase>[
          GoRoute(
            path: 'username',
            builder: (BuildContext context, GoRouterState state) =>
                const UsernameScreen(),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      forumApiClientProvider.overrideWithValue(FakeForumApiClient()),
    ],
    child: SizedBox(
      width: 440,
      height: 1100,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('UsernameScreen golden', () {
    goldenTest(
      'renders the username onboarding screen',
      fileName: 'username_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'set @username (care-circle connect)',
            child: _host(),
          ),
        ],
      ),
    );
  });
}

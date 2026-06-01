import 'package:alchemist/alchemist.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/team/invite_caregiver_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

Widget _host() {
  final GoRouter router = GoRouter(
    initialLocation: '/team/circle/invite',
    routes: <RouteBase>[
      GoRoute(
        path: '/team/circle',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
        routes: <RouteBase>[
          GoRoute(
            path: 'invite',
            builder: (BuildContext context, GoRouterState state) =>
                const InviteCaregiverScreen(),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      storageProvider.overrideWithValue(InMemoryStorageProvider()),
    ],
    child: SizedBox(
      width: 440,
      height: 1500,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('InviteCaregiverScreen golden', () {
    goldenTest(
      'renders the invite form',
      fileName: 'invite_caregiver_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'invite form (Phase 14.28)',
            child: _host(),
          ),
        ],
      ),
    );
  });
}

import 'package:alchemist/alchemist.dart';
import 'package:holdclose/screens/team/circle_qr_screen.dart';
import 'package:holdclose/services/fake_forum_api_client.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// Fixed clock so the [FakeForumApiClient] mints a deterministic invite
/// token (it derives ids from `clock().millisecondsSinceEpoch` + a
/// seeded RNG), which keeps the rendered QR modules identical run-to-run.
DateTime _fixedNow() => DateTime.utc(2026, 6, 1, 12);

GoRouter _router() => GoRouter(
      initialLocation: '/team/circle/qr',
      routes: <RouteBase>[
        GoRoute(
          path: '/team/circle',
          builder: (BuildContext c, GoRouterState s) =>
              const Scaffold(body: SizedBox.shrink()),
          routes: <RouteBase>[
            GoRoute(
              path: 'qr',
              builder: (BuildContext c, GoRouterState s) =>
                  const CircleQrScreen(),
            ),
          ],
        ),
      ],
    );

Widget _host() {
  return ProviderScope(
    overrides: <Override>[
      // Fixed-clock fake: createInvite mints a stable token offline, and
      // qr_flutter renders the QR purely from that token (no network).
      forumApiClientProvider
          .overrideWithValue(FakeForumApiClient(clock: _fixedNow)),
    ],
    child: SizedBox(
      width: 440,
      height: 1000,
      child: MaterialApp.router(
        routerConfig: _router(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  // _ensureInvite fires `_bindCircle` → SyncStateStore.setCircleId, which
  // reads shared_preferences (best-effort, fire-and-forget). Seed an empty
  // store so it resolves deterministically rather than throwing.
  SharedPreferences.setMockInitialValues(<String, Object>{});

  group('CircleQrScreen golden', () {
    goldenTest(
      'minted invite — scannable QR + 2-day caption + share link',
      fileName: 'circle_qr_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'invite QR',
            child: _host(),
          ),
        ],
      ),
    );
  });
}

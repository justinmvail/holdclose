import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/share_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:careblazers/screens/library/library_card_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI golden — Library card detail in its default populated state. The
/// `sundowning_basics` card has a multi-line body + two related
/// behaviors, so a single golden catches AppBar, PLAY button, body
/// typography, and chip-strip regressions in one pass.
void main() {
  group('LibraryCardScreen golden', () {
    goldenTest(
      'renders title + PLAY + body + related-behavior chips',
      fileName: 'library_card_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'default (§5.8 full layout)',
            child: ProviderScope(
              overrides: <Override>[
                ttsProvider
                    .overrideWith((Ref _) => const NoopTTSProvider()),
                ttsSettingsProvider.overrideWithValue(
                  AppSettings.defaults(),
                ),
                sharerProvider.overrideWithValue(RecordingSharer()),
              ],
              child: SizedBox(
                width: 420,
                height: 1100,
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
    initialLocation: '/library/sundowning_basics',
    routes: <RouteBase>[
      GoRoute(
        path: '/library/:id',
        builder: (BuildContext context, GoRouterState state) =>
            LibraryCardScreen(cardId: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/decoder/triage',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
}

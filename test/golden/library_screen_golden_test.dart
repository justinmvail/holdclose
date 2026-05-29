import 'package:alchemist/alchemist.dart';
import 'package:careblazers/screens/library/library_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pinned clock so the "Today's card" hero is deterministic across CI
/// runs — May 29, 2026 is day-of-year 149; 149 % 12 = 5, which lands
/// on the `accusations_basics` card.
final DateTime _fixedNow = DateTime(2026, 5, 29, 12, 0);

/// CI golden — Library tab root in its default populated state. Picks
/// the most visually-loaded layout (hero + both section headers + all
/// nine fixed-section tiles) so a single golden catches regressions in
/// the hero, section ordering, and tile typography in one pass.
void main() {
  group('LibraryScreen golden', () {
    goldenTest(
      "renders today's card hero + both fixed sections",
      fileName: 'library_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'default (§5.7 full layout)',
            child: ProviderScope(
              overrides: <Override>[
                libraryScreenClockProvider.overrideWithValue(() => _fixedNow),
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
    initialLocation: '/library',
    routes: <RouteBase>[
      GoRoute(
        path: '/library',
        builder: (BuildContext context, GoRouterState state) =>
            const LibraryScreen(),
      ),
      GoRoute(
        path: '/library/:id',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
}

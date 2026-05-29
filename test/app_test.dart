import 'package:careblazers/app.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/quiet_hours_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// BUILD_SPEC.md §11.3 — the app root must wrap MaterialApp's routed
/// child in a MediaQuery whose `textScaler` reflects the persisted
/// `AppSettings.fontSize.scale`. The settings notifier hydrates from
/// storage on the first microtask, so a non-default seed propagates to
/// every screen's `MediaQuery.textScalerOf(context)` without per-screen
/// plumbing.
Future<TextScaler> _pumpAndReadScaler(
  WidgetTester tester, {
  required FontSizeMultiplier fontSize,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  await storage.updateSettings(
    AppSettings.defaults().copyWith(fontSize: fontSize),
  );
  addTearDown(storage.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
        // Pin the clock before 6pm so `nightThemeModeProvider` doesn't
        // flip to dark mid-test — the assertion is about textScaler, not
        // the night theme. A late-afternoon stamp also keeps the quiet-
        // hours window inactive in case any subscreen reads it.
        quietHoursClockProvider.overrideWithValue(
          () => DateTime(2026, 5, 29, 14, 0),
        ),
      ],
      child: const CareblazersApp(),
    ),
  );
  // Drain the SettingsNotifier hydrate microtask so the persisted seed
  // replaces the AppSettings.defaults() initial state — without this
  // pump, every assertion would read the medium-default scaler.
  await tester.pump();

  // Sample MediaQuery from inside the routed subtree (the app root
  // wraps `MaterialApp.router`'s `child` in the MediaQuery override).
  final BuildContext context = tester.element(find.byType(HomeScreen));
  return MediaQuery.textScalerOf(context);
}

void main() {
  group('CareblazersApp — font scaler (BUILD_SPEC.md §11.3)', () {
    testWidgets('small fontSize applies 0.875× textScaler',
        (WidgetTester tester) async {
      final TextScaler scaler = await _pumpAndReadScaler(
        tester,
        fontSize: FontSizeMultiplier.small,
      );
      expect(scaler.scale(10), closeTo(8.75, 0.001));
    });

    testWidgets('medium fontSize applies 1.0× textScaler',
        (WidgetTester tester) async {
      final TextScaler scaler = await _pumpAndReadScaler(
        tester,
        fontSize: FontSizeMultiplier.medium,
      );
      expect(scaler.scale(10), closeTo(10.0, 0.001));
    });

    testWidgets('large fontSize applies 1.15× textScaler',
        (WidgetTester tester) async {
      final TextScaler scaler = await _pumpAndReadScaler(
        tester,
        fontSize: FontSizeMultiplier.large,
      );
      expect(scaler.scale(10), closeTo(11.5, 0.001));
    });

    testWidgets('xLarge fontSize applies 1.35× textScaler',
        (WidgetTester tester) async {
      final TextScaler scaler = await _pumpAndReadScaler(
        tester,
        fontSize: FontSizeMultiplier.xLarge,
      );
      expect(scaler.scale(10), closeTo(13.5, 0.001));
    });

    testWidgets(
        'route children read the same scaler '
        '(MediaQuery is wired below MaterialApp.router)',
        (WidgetTester tester) async {
      // Stand up a minimal injected router so the test doesn't depend on
      // the production route table — the contract under test is the
      // `MaterialApp.router(builder:)` MediaQuery wrap, not the route
      // map itself.
      const Key probeKey = Key('font-scale-probe');
      final GoRouter probeRouter = GoRouter(
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (BuildContext context, GoRouterState _) {
              final TextScaler s = MediaQuery.textScalerOf(context);
              return Scaffold(
                body: Text('scaled', key: probeKey, textScaler: s),
              );
            },
          ),
        ],
      );

      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      await storage.updateSettings(
        AppSettings.defaults().copyWith(fontSize: FontSizeMultiplier.xLarge),
      );
      addTearDown(storage.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            storageBackendProvider.overrideWithValue(storage),
            quietHoursClockProvider.overrideWithValue(
              () => DateTime(2026, 5, 29, 14, 0),
            ),
          ],
          child: CareblazersApp(router: probeRouter),
        ),
      );
      await tester.pump();

      final BuildContext probeContext = tester.element(find.byKey(probeKey));
      final TextScaler scaler = MediaQuery.textScalerOf(probeContext);
      expect(scaler.scale(10), closeTo(13.5, 0.001));
    });
  });
}

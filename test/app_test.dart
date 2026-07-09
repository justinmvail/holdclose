import 'dart:async';

import 'package:holdclose/app.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/models/settings.dart';
import 'package:holdclose/providers/auth_provider.dart';
import 'package:holdclose/providers/home_conversation_provider.dart';
import 'package:holdclose/providers/onboarding_provider.dart';
import 'package:holdclose/providers/quiet_hours_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/home_screen.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Minimal [AuthProvider] that boots straight into [AuthStateSignedIn].
///
/// The font-scaler tests don't exercise auth at all, but the production
/// router now applies the BUILD_SPEC.md §5.11 + §5.12 redirect — without
/// a signed-in state the router bounces `/` to `/sign-in`, hiding the
/// `HomeScreen` the tests sample `MediaQuery.textScalerOf` from.
class _SignedInAuthStub implements AuthProvider {
  _SignedInAuthStub();

  static const User _user = User(
    id: 'stub-app-test',
    email: 'app-test@holdclose.app',
    name: 'App Test Caregiver',
  );

  final StreamController<AuthState> _changes =
      StreamController<AuthState>.broadcast();

  Future<void> dispose() => _changes.close();

  @override
  Stream<AuthState> watchAuthState() async* {
    yield const AuthState.signedIn(user: _user);
    yield* _changes.stream;
  }

  @override
  Future<void> signInWithApple() async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async {}
}

/// `@Riverpod` notifier override that pretends the carousel was
/// completed in a prior session — pairs with [_SignedInAuthStub] to
/// keep the production redirect off the font-scaler tests' back.
class _CompletedOnboarding extends OnboardingCompleted {
  @override
  bool build() => true;
}

List<Override> _routerGateOverrides(_SignedInAuthStub auth) {
  final DateTime now = DateTime.utc(2026, 5, 30, 12);
  return <Override>[
    authBackendProvider.overrideWithValue(auth),
    onboardingCompletedProvider.overrideWith(_CompletedOnboarding.new),
    // Home tab resolves to a synthetic conversation so the chat-shaped
    // home renders without a drift database in the test harness.
    homeConversationProvider.overrideWith(
      (_) async => Conversation(
        id: 'app-test-conv',
        title: 'Today',
        createdAt: now,
        updatedAt: now,
      ),
    ),
  ];
}

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
  // Satisfy the loved-one setup gate (new-user wizard) so the wired
  // router lands on Home — these tests sample `MediaQuery` from the
  // HomeScreen subtree, and an un-configured patient would redirect to
  // `/setup` instead.
  await storage.upsertPatient(maryHenderson());
  addTearDown(storage.dispose);

  final _SignedInAuthStub auth = _SignedInAuthStub();
  addTearDown(auth.dispose);

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
        ..._routerGateOverrides(auth),
      ],
      child: const HoldcloseApp(),
    ),
  );
  // Drain the SettingsNotifier hydrate microtask AND the
  // `holdcloseRouterProvider`'s auth-stream subscription — the
  // production redirect (BUILD_SPEC.md §5.11 + §5.12) starts the
  // bridge in `signedOut`, so the very first redirect evaluation
  // would bounce `/` to `/sign-in` until the override's first
  // emission flips the bridge to `signedIn` and the listenable
  // re-triggers the redirect. `pumpAndSettle` lets both transitions
  // resolve before the test samples `MediaQuery.textScalerOf`.
  await tester.pumpAndSettle();

  // Sample MediaQuery from inside the routed subtree (the app root
  // wraps `MaterialApp.router`'s `child` in the MediaQuery override).
  final BuildContext context = tester.element(find.byType(HomeScreen));
  return MediaQuery.textScalerOf(context);
}

void main() {
  group('HoldcloseApp — font scaler (BUILD_SPEC.md §11.3)', () {
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
          child: HoldcloseApp(router: probeRouter),
        ),
      );
      await tester.pump();

      final BuildContext probeContext = tester.element(find.byKey(probeKey));
      final TextScaler scaler = MediaQuery.textScalerOf(probeContext);
      expect(scaler.scale(10), closeTo(13.5, 0.001));
    });

    testWidgets(
        'COMPOSES the OS text scaler with the in-app scale '
        '(a11y: an OS-wide enlargement is preserved, not discarded)',
        (WidgetTester tester) async {
      // Simulate a user who enlarged text OS-wide to 1.4×.
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      const Key probeKey = Key('font-scale-compose-probe');
      final GoRouter probeRouter = GoRouter(
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (BuildContext context, GoRouterState _) => const Scaffold(
              body: Text('scaled', key: probeKey),
            ),
          ),
        ],
      );

      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      // large in-app scale (1.15×) on top of the 1.4× OS scaler.
      await storage.updateSettings(
        AppSettings.defaults().copyWith(fontSize: FontSizeMultiplier.large),
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
          child: HoldcloseApp(router: probeRouter),
        ),
      );
      await tester.pump();

      final BuildContext probeContext = tester.element(find.byKey(probeKey));
      final TextScaler scaler = MediaQuery.textScalerOf(probeContext);
      // 1.4 (OS) × 1.15 (in-app) = 1.61 — under the 2.2 clamp ceiling.
      expect(scaler.scale(10), closeTo(16.1, 0.05));
    });

    testWidgets('CLAMPS the composed scaler so an extreme OS setting can\'t '
        'blow the layout apart', (WidgetTester tester) async {
      // An extreme OS scaler that, times xLarge (1.35), would exceed 2.2.
      tester.platformDispatcher.textScaleFactorTestValue = 3.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      const Key probeKey = Key('font-scale-clamp-probe');
      final GoRouter probeRouter = GoRouter(
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (BuildContext context, GoRouterState _) => const Scaffold(
              body: Text('scaled', key: probeKey),
            ),
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
          child: HoldcloseApp(router: probeRouter),
        ),
      );
      await tester.pump();

      final BuildContext probeContext = tester.element(find.byKey(probeKey));
      final TextScaler scaler = MediaQuery.textScalerOf(probeContext);
      // 3.0 × 1.35 = 4.05, clamped to the 2.2 ceiling.
      expect(scaler.scale(10), closeTo(22.0, 0.001));
    });
  });
}

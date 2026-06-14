import 'dart:async';

import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/bundled_tts_provider.dart';
import 'package:careblazers/providers/settings_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/widgets/careblazers_switch.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:careblazers/screens/settings/settings_screen.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pump the Settings screen behind a [ProviderScope] that overrides the
/// drift-backed storage with [InMemoryStorageProvider] (so tests neither
/// load `sqlite3` nor leak state) and pins [ttsProvider] to [NoopTTSProvider]
/// — the screen's voice-picker FutureBuilder otherwise hits the
/// flutter_tts platform channel, which in the widget-test FakeAsync zone
/// would never settle. The `ttsProvider` ↔ Settings selection contract
/// is exercised separately in the test group at the bottom of this file.
///
/// Surface sized tall enough that every section lands inside the
/// viewport — ListView lazy-renders, so off-screen sections aren't
/// findable by key until the user scrolls them on.
Future<({InMemoryStorageProvider storage, ProviderContainer container})>
    _pumpSettings(
  WidgetTester tester, {
  AppSettings? seeded,
}) async {
  // Tall surface so the whole settings list builds in one pass (the
  // gating test finds bottom-of-list section keys without scrolling).
  // Bumped from 2600 when the "Loved ones" section (Issue #6) was added.
  await tester.binding.setSurfaceSize(const Size(420, 2800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  if (seeded != null) {
    await storage.updateSettings(seeded);
  }
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      storageBackendProvider.overrideWithValue(storage),
      ttsProvider.overrideWith((Ref _) => const NoopTTSProvider()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  // `tester.pump()` drains the microtask queue (which is what runs the
  // SettingsNotifier's hydrate microtask scheduled in build()). Using
  // `Future.delayed(Duration.zero)` here would deadlock the FakeAsync
  // zone — widget tests must round-trip time through the tester.
  await tester.pump();
  return (storage: storage, container: container);
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200.0,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

/// Snapshot the value of the CareblazersSwitchListTile at [key]. Keeps the
/// Phase 12.8 tracker assertions concise — three of them flip the
/// same switch and re-read.
bool _switchValue(WidgetTester tester, Key key) {
  return tester.widget<CareblazersSwitchListTile>(find.byKey(key)).value;
}

void main() {
  group('SettingsScreen — BUILD_SPEC.md §5.10', () {
    testWidgets('renders PathHeader title and the top sections',
        (WidgetTester tester) async {
      await _pumpSettings(tester);

      // The page title now lives in PathHeader.title (the AppBar-based
      // header was replaced by the breadcrumb PathHeader). 'Settings'
      // renders twice inside the header — once as the terminal
      // breadcrumb crumb, once as the title — so scope the lookup to the
      // PathHeader and assert it carries the title text.
      expect(find.byType(PathHeader), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PathHeader),
          matching: find.text('Settings'),
        ),
        findsWidgets,
      );
      // Section headers anchored near the top of the viewport — visible
      // on the 2000-tall test surface without scrolling.
      expect(find.text('Font size'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      // Phase 12.8 — Trackers section appears below Appearance.
      expect(find.text('Trackers'), findsOneWidget);
    });

    testWidgets(
      'Phase 14.6 — Send reminders toggle persists through storage',
      (WidgetTester tester) async {
        final built = await _pumpSettings(tester);

        // The reminders toggle starts ON and is always interactive —
        // Phase 14.6 removed the master "Use trackers" gate.
        expect(_switchValue(tester, SettingsScreen.notificationsToggleKey),
            isTrue);
        final CareblazersSwitchListTile remindersTile = tester.widget<CareblazersSwitchListTile>(
            find.byKey(SettingsScreen.notificationsToggleKey));
        expect(remindersTile.onChanged, isNotNull,
            reason: 'reminders toggle is no longer gated on a master switch');

        await tester.tap(find.byKey(SettingsScreen.notificationsToggleKey));
        await tester.pumpAndSettle();

        // The flip persisted through storage.
        final AppSettings stored = await built.storage.getSettings();
        expect(stored.notificationsEnabled, isFalse);
      },
    );

    testWidgets(
      'quiet-hours window picker persists a custom start hour',
      (WidgetTester tester) async {
        final built = await _pumpSettings(tester);

        // Default window is 10pm–7am — the subtitle spells it out.
        expect(find.text('Mute audio between 10 PM and 7 AM.'), findsOneWidget);

        // Pick a new start hour (8 PM) from the start dropdown.
        await tester.ensureVisible(
            find.byKey(SettingsScreen.quietHoursStartPickerKey));
        await tester.tap(find.byKey(SettingsScreen.quietHoursStartPickerKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('8 PM').last);
        await tester.pumpAndSettle();

        // Persisted, and the subtitle now reflects the new window.
        final AppSettings stored = await built.storage.getSettings();
        expect(stored.quietHoursStartHour, 20);
        expect(stored.quietHoursEndHour, 7);
        expect(find.text('Mute audio between 8 PM and 7 AM.'), findsOneWidget);
      },
    );

    testWidgets(
      'appearance: selecting a mode persists themePreference',
      (WidgetTester tester) async {
        final built = await _pumpSettings(tester);

        // Default is "System" (match phone) — the hour pickers are
        // hidden until "Scheduled" is chosen.
        expect(find.byKey(SettingsScreen.darkStartPickerKey), findsNothing);
        expect(find.byKey(SettingsScreen.darkEndPickerKey), findsNothing);

        // Pick always-on dark.
        await tester.ensureVisible(
            find.byKey(SettingsScreen.themePreferenceKey));
        await tester.tap(find.text('On'));
        await tester.pumpAndSettle();

        final AppSettings stored = await built.storage.getSettings();
        expect(stored.themePreference, ThemePreference.on);
        // Pickers still hidden — they're scheduled-only.
        expect(find.byKey(SettingsScreen.darkStartPickerKey), findsNothing);
      },
    );

    testWidgets(
      'appearance: Scheduled reveals the hour pickers and persists window',
      (WidgetTester tester) async {
        final built = await _pumpSettings(tester);

        await tester.ensureVisible(
            find.byKey(SettingsScreen.themePreferenceKey));
        await tester.tap(find.text('Scheduled'));
        await tester.pumpAndSettle();

        // The From/To hour pickers appear once scheduled is selected.
        expect(
            find.byKey(SettingsScreen.darkStartPickerKey), findsOneWidget);
        expect(find.byKey(SettingsScreen.darkEndPickerKey), findsOneWidget);
        expect((await built.storage.getSettings()).themePreference,
            ThemePreference.scheduled);

        // Pick a new start hour (9 PM) from the start dropdown.
        await tester
            .ensureVisible(find.byKey(SettingsScreen.darkStartPickerKey));
        await tester.tap(find.byKey(SettingsScreen.darkStartPickerKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('9 PM').last);
        await tester.pumpAndSettle();

        final AppSettings stored = await built.storage.getSettings();
        expect(stored.darkStartHour, 21);
        expect(stored.darkEndHour, 7,
            reason: 'default end hour is unchanged');
        // Subtitle reflects the new window.
        expect(find.text('Dark between 9 PM and 7 AM.'), findsOneWidget);
      },
    );

    testWidgets(
      'demo-mode section hidden when DEMO_MODE define is unset',
      (WidgetTester tester) async {
        await _pumpSettings(tester);

        expect(find.byKey(SettingsScreen.demoSectionKey), findsNothing,
            reason: 'demoModeEnabled is false in the test harness; '
                'the demo section must not render');
        expect(find.byKey(SettingsScreen.resetOnLaunchToggleKey),
            findsNothing);
      },
    );

    testWidgets(
      'account section visible when DEMO_MODE is unset',
      (WidgetTester tester) async {
        await _pumpSettings(tester);
        expect(find.byKey(SettingsScreen.accountSectionKey), findsOneWidget);
        expect(find.byKey(SettingsScreen.signOutButtonKey), findsOneWidget);
        expect(
            find.byKey(SettingsScreen.deleteAccountButtonKey), findsOneWidget);
      },
    );

    testWidgets(
      'demoModeEnabled gating contract: exactly one of the two sections',
      (WidgetTester tester) async {
        await _pumpSettings(tester);
        // Whichever value the define lands at, only one of the two
        // sections renders. Codifies §5.10's visibility rules so a
        // future copy/paste mis-wire of either gate fails loudly.
        final bool demoVisible =
            find.byKey(SettingsScreen.demoSectionKey).evaluate().isNotEmpty;
        final bool accountVisible = find
            .byKey(SettingsScreen.accountSectionKey)
            .evaluate()
            .isNotEmpty;
        expect(demoVisible ^ accountVisible, isTrue,
            reason: 'Demo-mode and Account sections must be mutually '
                'exclusive — gated on opposite sides of DEMO_MODE.');
        expect(demoVisible, demoModeEnabled,
            reason: 'demo section visibility tracks the build define');
      },
    );

    testWidgets(
      'bundled-voice toggle renders ON by default and persists OFF',
      (WidgetTester tester) async {
        final ({InMemoryStorageProvider storage, ProviderContainer container})
            pumped = await _pumpSettings(tester);

        // Copy of the BUILD_SPEC.md §11.1 + Phase 9.5 subtitle so a
        // future rewording trips this test rather than silently
        // shipping a different recommendation strength.
        expect(find.text('High-quality bundled voice'), findsOneWidget);
        expect(
          find.textContaining('~30 MB of storage'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(SettingsScreen.bundledVoiceToggleKey));
        await tester.pump();

        expect(
          (await pumped.storage.getSettings()).useBundledVoice,
          isFalse,
          reason: 'tapping the bundled toggle should persist the opt-out',
        );
        expect(
          pumped.container.read(settingsProvider).useBundledVoice,
          isFalse,
        );
      },
    );

    testWidgets(
      'voice picker shows the single "Amy (bundled)" entry (v1.1 catalog '
      'expansion lands later)',
      (WidgetTester tester) async {
        await _pumpSettings(tester);
        expect(
          find.descendant(
            of: find.byKey(SettingsScreen.voicePickerKey),
            matching: find.text('Amy (bundled)'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'toggling Read scripts aloud OFF persists the change',
      (WidgetTester tester) async {
        final ({InMemoryStorageProvider storage, ProviderContainer container})
            pumped = await _pumpSettings(tester);

        await tester.tap(find.byKey(SettingsScreen.readAloudToggleKey));
        // One pump drains the storage.updateSettings Future (its body
        // is a couple of microtask hops on InMemoryStorageProvider).
        await tester.pump();

        expect(
          (await pumped.storage.getSettings()).readScriptsAloud,
          isFalse,
        );
        expect(
          pumped.container.read(settingsProvider).readScriptsAloud,
          isFalse,
        );
      },
    );

    testWidgets(
      'changing font size persists the multiplier through storage',
      (WidgetTester tester) async {
        final ({InMemoryStorageProvider storage, ProviderContainer container})
            pumped = await _pumpSettings(tester);

        await tester.tap(find.text('Large'));
        await tester.pump();

        expect(
          (await pumped.storage.getSettings()).fontSize,
          FontSizeMultiplier.large,
        );
        expect(
          pumped.container.read(settingsProvider).fontSize,
          FontSizeMultiplier.large,
        );
      },
    );

    testWidgets(
      'About shows only the app version — no methodology / brand-credit cards',
      (WidgetTester tester) async {
        await _pumpSettings(tester);

        await _scrollTo(tester, find.text('App version'));
        expect(find.text('App version'), findsOneWidget);
        // The methodology + brand-credit cards were removed (06-06).
        expect(find.text('Methodology'), findsNothing);
        expect(find.textContaining('permission pending'), findsNothing);
        expect(find.textContaining("words 'AI'"), findsNothing);
      },
    );
  });

  group('SettingsScreen ↔ TTS selection (§5.10 + §6.3)', () {
    test(
      'persisting readScriptsAloud=false flips ttsProvider to Noop',
      () async {
        // Pure-Dart provider test — no widget tree, no FakeAsync zone.
        // Uses `Future.delayed(Duration.zero)` to drain the hydrate
        // microtask between mutations (the trick that deadlocks in
        // widget tests above).
        final InMemoryStorageProvider storage = InMemoryStorageProvider();
        final ProviderContainer container = ProviderContainer(
          overrides: <Override>[
            storageBackendProvider.overrideWithValue(storage),
            ttsSettingsProvider.overrideWith(
              (Ref ref) => ref.watch(settingsProvider),
            ),
            ttsClockProvider.overrideWithValue(
              () => DateTime(2026, 5, 29, 14, 0), // outside quiet hours
            ),
          ],
        );
        addTearDown(container.dispose);

        container.read(settingsProvider);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(ttsProvider), isA<BundledTTSProvider>(),
            reason: 'default audio=true must resolve to the bundled '
                'neural-TTS path (Phase 9.5)');

        await container
            .read(settingsProvider.notifier)
            .setReadScriptsAloud(false);

        expect(container.read(ttsProvider), isA<NoopTTSProvider>(),
            reason: 'toggling audio off must flip ttsProvider to Noop');
        expect(
          (await storage.getSettings()).readScriptsAloud,
          isFalse,
          reason: 'and the toggle must persist through storage',
        );
      },
    );
  });

  group('SettingsScreen ↔ font multiplier wiring (§11.3)', () {
    testWidgets(
      'app-root MediaQuery.textScaler reflects the persisted font size',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(420, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final InMemoryStorageProvider storage = InMemoryStorageProvider();
        await storage.updateSettings(
          AppSettings.defaults().copyWith(fontSize: FontSizeMultiplier.xLarge),
        );

        TextScaler? observed;
        // Pump twice: the first frame renders with the default font
        // size (medium), then the hydrate microtask flips state to the
        // persisted X-Large value and a second pump re-renders with
        // the new scaler.
        Future<void> pumpRig() => tester.pumpWidget(
              ProviderScope(
                overrides: <Override>[
                  storageBackendProvider.overrideWithValue(storage),
                ],
                child: MaterialApp(
                  builder: (BuildContext context, Widget? child) {
                    final FontSizeMultiplier fontSize =
                        ProviderScope.containerOf(context)
                            .read(settingsProvider)
                            .fontSize;
                    final MediaQueryData base = MediaQuery.of(context);
                    return MediaQuery(
                      data: base.copyWith(
                        textScaler: TextScaler.linear(fontSize.scale),
                      ),
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                  home: Builder(
                    builder: (BuildContext context) {
                      observed = MediaQuery.textScalerOf(context);
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),
            );

        await pumpRig();
        // Drain the hydrate microtask and re-pump so the builder
        // re-reads `settingsProvider`. `tester.pump()` drains
        // microtasks before scheduling a new frame.
        await tester.pump();
        await pumpRig();
        await tester.pump();

        expect(observed, isNotNull);
        expect(observed!.scale(10.0), closeTo(13.5, 0.01),
            reason: 'X-Large ramp is 1.35× per BUILD_SPEC.md §3.2');
      },
    );

    test(
      'FontSizeMultiplier scale values match the BUILD_SPEC.md §3.2 ramp',
      () {
        expect(FontSizeMultiplier.small.scale, closeTo(0.875, 0.001));
        expect(FontSizeMultiplier.medium.scale, closeTo(1.0, 0.001));
        expect(FontSizeMultiplier.large.scale, closeTo(1.15, 0.001));
        expect(FontSizeMultiplier.xLarge.scale, closeTo(1.35, 0.001));
      },
    );
  });

  group('SettingsScreen — Android system back routes Home (alpha bug)', () {
    // Amanda (Android, 2026-06-07): hardware Back from /settings closed the
    // whole app instead of returning Home. Settings lives on the root
    // navigator above the tab shell; a system pop there could tear the
    // whole stack down. The screen's PopScope must block the system pop
    // and `router.go('/')` instead — deterministically, regardless of how
    // /settings was entered.

    /// Build a router with a Home landing + a pushed `/settings`, pump it,
    /// and navigate to Settings. Returns the router so the test can read
    /// the active location after firing a system back.
    Future<GoRouter> pumpRouterAtSettings(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 2800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final GlobalKey<NavigatorState> rootKey =
          GlobalKey<NavigatorState>();
      final GoRouter router = GoRouter(
        initialLocation: '/',
        navigatorKey: rootKey,
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: Center(child: Text('home-stub'))),
          ),
          GoRoute(
            path: '/settings',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                const SettingsScreen(),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            storageBackendProvider
                .overrideWithValue(InMemoryStorageProvider()),
            ttsProvider.overrideWith((Ref _) => const NoopTTSProvider()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Land on Settings the way Home does (push onto the root navigator).
      unawaited(router.push('/settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      return router;
    }

    testWidgets(
      'a hardware/gesture back from Settings lands on Home, not an app exit',
      (WidgetTester tester) async {
        final GoRouter router = await pumpRouterAtSettings(tester);

        // Fire the Android system back the way the OS does — through the
        // app-lifecycle pop-route dispatcher, which drives the PopScope.
        final bool handled =
            await WidgetsBinding.instance.handlePopRoute();
        await tester.pumpAndSettle();

        // The app handled the back (didn't bubble it up to the OS to close
        // the app) and routed to Home.
        expect(handled, isTrue,
            reason: 'the PopScope must consume the system back');
        expect(router.routerDelegate.currentConfiguration.uri.path, '/',
            reason: 'Android back from Settings must return Home');
        expect(find.text('home-stub'), findsOneWidget);
        expect(find.byType(SettingsScreen), findsNothing);
      },
    );

    testWidgets(
      'the PopScope blocks the pop (canPop false) so the route stack is '
      'never torn down by the system',
      (WidgetTester tester) async {
        await pumpRouterAtSettings(tester);

        // With a router in scope the screen wires canPop=false so the
        // system pop never reaches the navigator — the redirect Home is
        // the only way out. Assert the wiring directly. PopScope is
        // generic (PopScope<T>), so match it by runtime-type name rather
        // than a typed byType lookup.
        final Iterable<Widget> popScopes = tester
            .widgetList(find.byWidgetPredicate(
                (Widget w) => w.runtimeType.toString().startsWith('PopScope')))
            .toList();
        expect(popScopes, isNotEmpty,
            reason: 'Settings wraps its body in a PopScope');
        final bool anyBlocks = popScopes.any((Widget w) {
          final dynamic d = w;
          return d.canPop == false;
        });
        expect(anyBlocks, isTrue,
            reason: 'a router-backed Settings must intercept the system back '
                '(canPop == false)');
      },
    );
  });
}

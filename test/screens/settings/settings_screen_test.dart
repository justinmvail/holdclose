import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/settings_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:careblazers/screens/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  await tester.binding.setSurfaceSize(const Size(420, 2000));
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

void main() {
  group('SettingsScreen — BUILD_SPEC.md §5.10', () {
    testWidgets('renders AppBar title and the top sections',
        (WidgetTester tester) async {
      await _pumpSettings(tester);

      expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
      // Section headers anchored near the top of the viewport — visible
      // on the 2000-tall test surface without scrolling.
      expect(find.text('Font size'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
    });

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
      'methodology card explains the LLM transparency carve-out',
      (WidgetTester tester) async {
        await _pumpSettings(tester);

        await _scrollTo(
            tester, find.byKey(SettingsScreen.methodologyButtonKey));
        await tester.tap(find.byKey(SettingsScreen.methodologyButtonKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          find.textContaining("Dr. Natali Edmonds' teaching framework"),
          findsOneWidget,
        );
        // §5.10 — the disclosure must own the only mention of "AI".
        expect(find.textContaining("words 'AI'"), findsOneWidget);
      },
    );

    testWidgets(
      'brand credit card carries the permission-pending v1 note',
      (WidgetTester tester) async {
        await _pumpSettings(tester);

        await _scrollTo(tester, find.byKey(SettingsScreen.brandCreditKey));

        expect(
          find.textContaining('permission pending'),
          findsOneWidget,
        );
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
        expect(container.read(ttsProvider), isA<OSTTSProvider>(),
            reason: 'default audio=true must resolve to OS TTS');

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
}

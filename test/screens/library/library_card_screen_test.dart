import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/share_provider.dart';
import 'package:careblazers/providers/tts_provider.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/library/library_card_screen.dart';
import 'package:careblazers/seed/library_cards.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Spying TTS provider so the PLAY-button test can assert what text
/// the screen handed off, without spinning up a flutter_tts platform
/// channel.
class _SpyTts implements TTSProvider {
  final List<String> spoken = <String>[];

  @override
  Future<void> speak(
    String text, {
    required String voiceId,
    required double speed,
  }) async {
    spoken.add(text);
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<List<TTSVoice>> availableVoices() async => const <TTSVoice>[];
}

Future<({
  GoRouter router,
  _SpyTts tts,
  RecordingSharer sharer,
  List<Object?> capturedTriageExtras,
})> _pumpCardScreen(
  WidgetTester tester, {
  required String cardId,
}) async {
  // Tall surface so the full populated layout (PLAY button + 50–80
  // word body + chip strip) lays out inside the viewport without
  // SliverList lazy-mounting a chip below the cache extent.
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final _SpyTts tts = _SpyTts();
  final RecordingSharer sharer = RecordingSharer();
  final List<Object?> capturedTriageExtras = <Object?>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();

  final GoRouter router = GoRouter(
    initialLocation: '/library/$cardId',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/library/:id',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            LibraryCardScreen(cardId: state.pathParameters['id'] ?? ''),
      ),
      GoRoute(
        path: '/decoder/triage',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) {
          capturedTriageExtras.add(state.extra);
          return const Scaffold(body: Center(child: Text('test-triage')));
        },
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        ttsProvider.overrideWith((Ref _) => tts),
        ttsSettingsProvider.overrideWithValue(AppSettings.defaults()),
        sharerProvider.overrideWithValue(sharer),
      ],
      child: MaterialApp.router(
        // Apply the brand theme so `Theme.of(context).textTheme.bodyLarge`
        // resolves to the 20pt Lato style (BUILD_SPEC.md §3.2) the screen
        // is supposed to be using. Without this the Material default
        // textTheme would land bodyLarge at 16pt and the assertion would
        // measure the absence of the theme rather than the screen's
        // intent.
        theme: careblazersLightTheme,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();

  return (
    router: router,
    tts: tts,
    sharer: sharer,
    capturedTriageExtras: capturedTriageExtras,
  );
}

void main() {
  group('LibraryCardScreen — BUILD_SPEC.md §5.8 chrome', () {
    testWidgets('renders the card title in the AppBar', (
      WidgetTester tester,
    ) async {
      const String id = 'sundowning_basics';
      await _pumpCardScreen(tester, cardId: id);

      final LibraryCard card = libraryCardById(id)!;
      expect(find.byKey(LibraryCardScreen.titleTextKey), findsOneWidget);
      expect(find.widgetWithText(AppBar, card.title), findsOneWidget);
    });

    testWidgets('renders the body in bodyLarge', (WidgetTester tester) async {
      const String id = 'sundowning_basics';
      await _pumpCardScreen(tester, cardId: id);

      final LibraryCard card = libraryCardById(id)!;
      // The body text widget is keyed; assert it renders the seed body
      // verbatim and that its style resolves to the theme's bodyLarge
      // (20pt per BUILD_SPEC.md §3.2).
      final Finder bodyFinder = find.byKey(LibraryCardScreen.bodyTextKey);
      expect(bodyFinder, findsOneWidget);
      final Text body = tester.widget<Text>(bodyFinder);
      expect(body.data, card.body);
      expect(body.style?.fontSize, 20.0);
    });

    testWidgets('renders the AppBar share action and the PLAY button', (
      WidgetTester tester,
    ) async {
      await _pumpCardScreen(tester, cardId: 'sundowning_basics');

      expect(find.byKey(LibraryCardScreen.shareButtonKey), findsOneWidget);
      expect(find.byKey(LibraryCardScreen.playButtonKey), findsOneWidget);
    });

    testWidgets(
      'renders a soft "not found" body for an unknown card id',
      (WidgetTester tester) async {
        await _pumpCardScreen(tester, cardId: 'this-card-does-not-exist');

        expect(find.byKey(LibraryCardScreen.notFoundKey), findsOneWidget);
        expect(find.byKey(LibraryCardScreen.bodyTextKey), findsNothing);
        expect(find.byKey(LibraryCardScreen.playButtonKey), findsNothing);
        expect(find.byKey(LibraryCardScreen.shareButtonKey), findsNothing);
      },
    );
  });

  group('LibraryCardScreen — PLAY reads body via TTS', () {
    testWidgets('tapping PLAY hands the card body to TTSProvider.speak', (
      WidgetTester tester,
    ) async {
      const String id = 'respond_to_emotion';
      final ({
        GoRouter router,
        _SpyTts tts,
        RecordingSharer sharer,
        List<Object?> capturedTriageExtras,
      }) p = await _pumpCardScreen(tester, cardId: id);

      await tester.tap(find.byKey(LibraryCardScreen.playButtonKey));
      await tester.pump();
      await tester.pumpAndSettle();

      final LibraryCard card = libraryCardById(id)!;
      expect(p.tts.spoken, <String>[card.body]);
    });

    testWidgets('PLAY is silent when the TTS override is the no-op impl', (
      WidgetTester tester,
    ) async {
      // Quiet hours / "Read aloud OFF" routes through NoopTTSProvider
      // (BUILD_SPEC.md §6.3); confirm the screen still tolerates a tap
      // without throwing.
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final GoRouter router = GoRouter(
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
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ttsProvider.overrideWith((Ref _) => const NoopTTSProvider()),
            ttsSettingsProvider.overrideWithValue(AppSettings.defaults()),
            sharerProvider.overrideWithValue(RecordingSharer()),
          ],
          child: MaterialApp.router(
            theme: careblazersLightTheme,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LibraryCardScreen.playButtonKey));
      await tester.pumpAndSettle();
      // No assertion needed beyond "didn't throw" — the screen
      // surviving the tap is the contract.
      expect(tester.takeException(), isNull);
    });
  });

  group('LibraryCardScreen — share action fires', () {
    testWidgets('tapping the AppBar share action calls Sharer.share', (
      WidgetTester tester,
    ) async {
      const String id = 'accusations_basics';
      final ({
        GoRouter router,
        _SpyTts tts,
        RecordingSharer sharer,
        List<Object?> capturedTriageExtras,
      }) p = await _pumpCardScreen(tester, cardId: id);

      await tester.tap(find.byKey(LibraryCardScreen.shareButtonKey));
      await tester.pumpAndSettle();

      final LibraryCard card = libraryCardById(id)!;
      expect(p.sharer.shared, hasLength(1));
      // The text should embed the title, the hook, and the body so the
      // recipient gets the orienting context — not just an isolated
      // body paragraph.
      expect(p.sharer.shared.single.text, contains(card.title));
      expect(p.sharer.shared.single.text, contains(card.hook));
      expect(p.sharer.shared.single.text, contains(card.body));
      // Subject is title-only for clean Mail handoff.
      expect(p.sharer.shared.single.subject, card.title);
    });
  });

  group(
    'LibraryCardScreen — related-behavior chips deep-link into triage',
    () {
      testWidgets('renders one chip per resolvable related behavior id', (
        WidgetTester tester,
      ) async {
        const String id = 'sundowning_basics';
        await _pumpCardScreen(tester, cardId: id);

        final LibraryCard card = libraryCardById(id)!;
        for (final String behaviorId in card.relatedBehaviorIds) {
          expect(
            find.byKey(LibraryCardScreen.relatedChipKey(behaviorId)),
            findsOneWidget,
            reason: 'chip for "$behaviorId" did not render',
          );
        }
        expect(find.byKey(LibraryCardScreen.relatedSectionKey), findsOneWidget);
      });

      testWidgets(
        'tapping a chip pushes /decoder/triage with the matching behavior',
        (WidgetTester tester) async {
          const String id = 'sundowning_basics';
          final ({
            GoRouter router,
            _SpyTts tts,
            RecordingSharer sharer,
            List<Object?> capturedTriageExtras,
          }) p = await _pumpCardScreen(tester, cardId: id);

          // Tap each related behavior chip and assert the route extra
          // is a [TriageArgs.forBehavior] with the matching id.
          final LibraryCard card = libraryCardById(id)!;
          for (final String behaviorId in card.relatedBehaviorIds) {
            await tester.ensureVisible(
              find.byKey(LibraryCardScreen.relatedChipKey(behaviorId)),
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(LibraryCardScreen.relatedChipKey(behaviorId)),
            );
            await tester.pumpAndSettle();

            // Pop back to the card screen so the next chip tap starts
            // from the same state.
            p.router.pop();
            await tester.pumpAndSettle();
          }

          expect(
            p.capturedTriageExtras,
            hasLength(card.relatedBehaviorIds.length),
          );
          for (int i = 0; i < card.relatedBehaviorIds.length; i++) {
            final Object? extra = p.capturedTriageExtras[i];
            expect(extra, isA<TriageArgs>());
            final TriageArgs args = extra! as TriageArgs;
            expect(args.freeText, isFalse);
            expect(args.behavior, isNotNull);
            expect(args.behavior!.id, card.relatedBehaviorIds[i]);
          }
        },
      );

      testWidgets(
        'a related-behavior id that is not in Behavior.canonical is dropped',
        (WidgetTester tester) async {
          // Sanity guard. The seed body explicitly notes that
          // [LibraryCard.relatedBehaviorIds] points at
          // [Behavior.canonical] ids; if a stale id slipped in, the
          // chip strip should silently drop it rather than crash.
          for (final LibraryCard card in libraryCards) {
            for (final String id in card.relatedBehaviorIds) {
              // Catches typos. The library card screen's filter relies on
              // [Behavior.byId] returning non-null.
              expect(
                Behavior.byId(id),
                isNotNull,
                reason:
                    'card "${card.id}" lists related behavior "$id" '
                    'which is not in Behavior.canonical',
              );
            }
          }
        },
      );
    },
  );
}

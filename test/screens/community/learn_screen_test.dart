import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/routing/router.dart' show CareblazersRoutes;
import 'package:careblazers/screens/community/learn_playbook_detail_screen.dart';
import 'package:careblazers/screens/community/learn_screen.dart';
import 'package:careblazers/seed/learn_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pumps the bare [LearnScreen] (the in-tab segment body) on a tall
/// surface so the lazy [ListView] builds every video card + playbook row
/// for the rendering assertions.
Future<void> _pumpScreen(WidgetTester tester,
    {LinkLauncher? launcher}) async {
  await tester.binding.setSurfaceSize(const Size(500, 6500));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        if (launcher != null)
          linkLauncherProvider.overrideWithValue(launcher),
      ],
      child: const MaterialApp(home: Scaffold(body: LearnScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

/// A minimal router hosting the Learn segment + the pushed playbook detail
/// route so `context.pushNamed` resolves the same name the real router
/// registers (Phase 14.37). Video cards no longer route — they deep-link
/// to YouTube via the launcher — so only the playbook route is wired here.
GoRouter _buildTestRouter() {
  return GoRouter(
    initialLocation: '/community',
    routes: <RouteBase>[
      GoRoute(
        path: '/community',
        builder: (BuildContext _, GoRouterState __) =>
            const Scaffold(body: LearnScreen()),
      ),
      GoRoute(
        path: '/community/learn/playbooks/:id',
        name: CareblazersRoutes.communityLearnPlaybook,
        builder: (BuildContext _, GoRouterState state) =>
            LearnPlaybookDetailScreen(
          playbookId: state.pathParameters['id'] ?? '',
        ),
      ),
    ],
  );
}

Future<GoRouter> _pumpRouted(WidgetTester tester,
    {LinkLauncher? launcher}) async {
  await tester.binding.setSurfaceSize(const Size(500, 6500));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final GoRouter router = _buildTestRouter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        if (launcher != null)
          linkLauncherProvider.overrideWithValue(launcher),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('LearnScreen — list rendering (Phase 14.37)', () {
    testWidgets('renders the Videos + Playbooks section headers',
        (WidgetTester tester) async {
      await _pumpScreen(tester);

      expect(find.text('Videos'), findsOneWidget);
      expect(find.text('Playbooks'), findsOneWidget);
    });

    testWidgets('renders a tappable card for every seeded video',
        (WidgetTester tester) async {
      await _pumpScreen(tester);

      for (final LearnVideo video in learnVideos) {
        expect(
          find.byKey(LearnScreen.videoCardKey(video.id)),
          findsOneWidget,
          reason: '${video.id} card should render',
        );
        expect(find.text(video.title), findsOneWidget);
        // The whole card carries the YouTube semantics label so screen
        // readers announce a single "Play <title> on YouTube" button.
        expect(
          find.byWidgetPredicate(
            (Widget w) =>
                w is Semantics &&
                w.properties.button == true &&
                w.properties.label == 'Play ${video.title} on YouTube',
          ),
          findsOneWidget,
          reason: '${video.id} card should expose a YouTube semantics label',
        );
      }
      // Sanity: the seed actually has videos to show.
      expect(learnVideos, isNotEmpty);
    });

    testWidgets('groups playbooks under a header for every non-empty topic',
        (WidgetTester tester) async {
      await _pumpScreen(tester);

      for (final LearnTopic topic in LearnTopic.values) {
        final List<LearnPlaybook> playbooks = learnPlaybooksForTopic(topic);
        if (playbooks.isEmpty) continue;
        expect(
          find.byKey(LearnScreen.topicHeaderKey(topic)),
          findsOneWidget,
          reason: '${topic.name} header should render',
        );
        for (final LearnPlaybook playbook in playbooks) {
          expect(
            find.byKey(LearnScreen.playbookRowKey(playbook.id)),
            findsOneWidget,
            reason: '${playbook.id} row should render',
          );
        }
      }
    });
  });

  group('LearnScreen — navigation (Phase 14.37)', () {
    testWidgets('tapping a video card deep-links straight to YouTube',
        (WidgetTester tester) async {
      final RecordingLinkLauncher launcher = RecordingLinkLauncher();
      // No router needed — the card hands the URL to the launcher directly
      // (no in-app detail screen anymore; fb_1780932492880889).
      await _pumpScreen(tester, launcher: launcher);

      final LearnVideo video = learnVideos.first;
      final Finder card = find.byKey(LearnScreen.videoCardKey(video.id));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();

      // The real Dementia Careblazers video URL is handed to the launcher,
      // with no intervening detail screen.
      expect(launcher.launched, hasLength(1));
      expect(launcher.launched.single.toString(), video.youtubeUrl);
    });

    testWidgets(
        'a playbook row pushes the playbook detail with its ordered steps',
        (WidgetTester tester) async {
      await _pumpRouted(tester);

      final LearnPlaybook playbook = learnPlaybooks.first;
      final Finder row = find.byKey(LearnScreen.playbookRowKey(playbook.id));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(find.byType(LearnPlaybookDetailScreen), findsOneWidget);
      // One step card per seeded step, in order.
      for (int i = 0; i < playbook.steps.length; i++) {
        expect(
          find.byKey(LearnPlaybookDetailScreen.stepCardKey(i)),
          findsOneWidget,
        );
      }
    });
  });

  group('Learn detail screens — missing content (Phase 14.37)', () {
    testWidgets('playbook detail shows a soft missing view for an unknown id',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: LearnPlaybookDetailScreen(playbookId: 'does-not-exist'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(LearnPlaybookDetailScreen.missingKey), findsOneWidget);
      expect(find.byKey(LearnPlaybookDetailScreen.stepCardKey(0)), findsNothing);
    });
  });

  group('learn_content seed (Phase 14.37)', () {
    test('lookup helpers resolve seeded ids and reject unknown ones', () {
      expect(learnVideoById(learnVideos.first.id), isNotNull);
      expect(learnVideoById('nope'), isNull);
      expect(learnPlaybookById(learnPlaybooks.first.id), isNotNull);
      expect(learnPlaybookById('nope'), isNull);
    });

    test('every playbook belongs to one of the locked topics', () {
      for (final LearnPlaybook playbook in learnPlaybooks) {
        expect(LearnTopic.values, contains(playbook.topic));
        expect(playbook.steps, isNotEmpty);
      }
    });

    test('durationLabel renders m:ss with a zero-padded seconds field', () {
      const LearnVideo v = LearnVideo(
        id: 'x',
        title: 't',
        youtubeId: 'abc123',
        duration: Duration(minutes: 8, seconds: 5),
        blurb: 'b',
      );
      expect(v.durationLabel, '8:05');
    });

    test('durationLabel is null when no duration is set', () {
      const LearnVideo v = LearnVideo(
        id: 'x',
        title: 't',
        youtubeId: 'abc123',
        blurb: 'b',
      );
      expect(v.durationLabel, isNull);
    });

    test('every seeded video is a real Careblazers YouTube link', () {
      for (final LearnVideo v in learnVideos) {
        expect(v.youtubeId, isNotEmpty);
        expect(v.youtubeUrl, 'https://www.youtube.com/watch?v=${v.youtubeId}');
      }
    });
  });
}

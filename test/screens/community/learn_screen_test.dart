import 'package:careblazers/routing/router.dart' show CareblazersRoutes;
import 'package:careblazers/screens/community/learn_playbook_detail_screen.dart';
import 'package:careblazers/screens/community/learn_screen.dart';
import 'package:careblazers/screens/community/learn_video_detail_screen.dart';
import 'package:careblazers/seed/learn_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Pumps the bare [LearnScreen] (the in-tab segment body) on a tall
/// surface so the lazy [ListView] builds every video card + playbook row
/// for the rendering assertions.
Future<void> _pumpScreen(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(500, 4000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: LearnScreen())),
  );
  await tester.pumpAndSettle();
}

/// A minimal router hosting the Learn segment + the two pushed detail
/// routes so `context.pushNamed` resolves the same names the real router
/// registers (Phase 14.37).
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
        path: '/community/learn/videos/:id',
        name: CareblazersRoutes.communityLearnVideo,
        builder: (BuildContext _, GoRouterState state) =>
            LearnVideoDetailScreen(videoId: state.pathParameters['id'] ?? ''),
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

Future<GoRouter> _pumpRouted(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(500, 4000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final GoRouter router = _buildTestRouter();
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
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

    testWidgets('renders a card + Watch button for every seeded video',
        (WidgetTester tester) async {
      await _pumpScreen(tester);

      for (final LearnVideo video in learnVideos) {
        expect(
          find.byKey(LearnScreen.videoCardKey(video.id)),
          findsOneWidget,
          reason: '${video.id} card should render',
        );
        expect(
          find.byKey(LearnScreen.watchButtonKey(video.id)),
          findsOneWidget,
          reason: '${video.id} watch button should render',
        );
        expect(find.text(video.title), findsOneWidget);
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
    testWidgets('Watch pushes the video detail at /community/learn/videos/:id',
        (WidgetTester tester) async {
      await _pumpRouted(tester);

      final String id = learnVideos.first.id;
      final Finder watch = find.byKey(LearnScreen.watchButtonKey(id));
      await tester.ensureVisible(watch);
      await tester.tap(watch);
      await tester.pumpAndSettle();

      // The pushed video detail renders its soft placeholder body.
      expect(find.byType(LearnVideoDetailScreen), findsOneWidget);
      expect(
        find.byKey(LearnVideoDetailScreen.placeholderKey),
        findsOneWidget,
      );
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
    testWidgets('video detail shows a soft missing view for an unknown id',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: LearnVideoDetailScreen(videoId: 'does-not-exist'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(LearnVideoDetailScreen.missingKey), findsOneWidget);
      expect(find.byKey(LearnVideoDetailScreen.placeholderKey), findsNothing);
    });

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
        duration: Duration(minutes: 8, seconds: 5),
        blurb: 'b',
      );
      expect(v.durationLabel, '8:05');
    });
  });
}

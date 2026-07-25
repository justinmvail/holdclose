import 'package:holdclose/providers/link_launcher_provider.dart';
import 'package:holdclose/routing/router.dart' show HoldcloseRoutes;
import 'package:holdclose/screens/community/learn_playbook_detail_screen.dart';
import 'package:holdclose/screens/community/learn_screen.dart';
import 'package:holdclose/seed/learn_content.dart';
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
        name: HoldcloseRoutes.communityLearnPlaybook,
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
    testWidgets('shows the Playbooks header; hides Videos while none seeded',
        (WidgetTester tester) async {
      await _pumpScreen(tester);

      expect(find.text('Playbooks'), findsOneWidget);
      // The curated video list is empty; the whole Videos section
      // (header + cards) hides until licensed videos are seeded.
      expect(learnVideos, isEmpty);
      expect(find.text('Videos'), findsNothing);
    });

    testWidgets('renders no video cards while the seed list is empty',
        (WidgetTester tester) async {
      await _pumpScreen(tester);

      // No seeded videos → no video cards anywhere in the list.
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Semantics &&
              (w.properties.label?.startsWith('Play ') ?? false),
        ),
        findsNothing,
      );
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
    // The video deep-link path (a tap hands the URL to the launcher with no
    // in-app detail screen; fb_1780932492880889) is retained in the screen
    // for when licensed videos return, but there are no seeded videos to tap
    // today, so the behavior isn't exercisable here.

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
      // No seeded videos today, so only the negative video lookup is
      // exercisable; the playbook lookups still resolve a real id.
      if (learnVideos.isNotEmpty) {
        expect(learnVideoById(learnVideos.first.id), isNotNull);
      }
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

    test('every seeded video is a real Holdclose YouTube link', () {
      for (final LearnVideo v in learnVideos) {
        expect(v.youtubeId, isNotEmpty);
        expect(v.youtubeUrl, 'https://www.youtube.com/watch?v=${v.youtubeId}');
      }
    });
  });
}

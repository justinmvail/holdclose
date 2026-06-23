import 'package:alchemist/alchemist.dart';
import 'package:holdclose/l10n/app_localizations.dart';
import 'package:holdclose/models/forum.dart';
import 'package:holdclose/screens/community/post_compose_screen.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// Deterministic [ForumApiClient]. The compose screen only calls the
/// client on submit (createPost) + the feed refresh (listPosts); the
/// static render touches neither, but the stubs keep the keepAlive feed
/// notifier from blowing up if it's read.
class _FakeForumApiClient extends ForumApiClient {
  _FakeForumApiClient()
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async =>
      const <ForumPost>[];
}

GoRouter _router() => GoRouter(
      initialLocation: '/community/compose',
      routes: <RouteBase>[
        GoRoute(
          path: '/community/compose',
          builder: (BuildContext context, GoRouterState state) =>
              const PostComposeScreen(),
        ),
      ],
    );

Widget _host() {
  return ProviderScope(
    overrides: <Override>[
      forumApiClientProvider.overrideWithValue(_FakeForumApiClient()),
    ],
    child: SizedBox(
      width: 420,
      height: 900,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: _router(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  // The guidelines-ack flow reads shared_preferences on submit; seed an
  // empty store so any incidental read resolves deterministically.
  SharedPreferences.setMockInitialValues(<String, Object>{});

  group('PostComposeScreen golden', () {
    goldenTest(
      'new-post compose — title + body fields with counters',
      fileName: 'post_compose_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'compose (empty draft)',
            child: _host(),
          ),
        ],
      ),
    );
  });
}

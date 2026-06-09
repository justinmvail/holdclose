import 'package:careblazers/l10n/app_localizations.dart';
import 'package:careblazers/models/forum.dart';
import 'package:careblazers/providers/guidelines_acknowledged_provider.dart';
import 'package:careblazers/screens/community/post_compose_screen.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

class _FakeForumApiClient extends ForumApiClient {
  _FakeForumApiClient()
      : super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final List<({String title, String body})> calls =
      <({String title, String body})>[];
  ForumApiException? nextError;
  ForumCrisisResources? crisisResources;

  @override
  Future<ForumCreatePostResponse> createPost({
    required String title,
    required String body,
  }) async {
    calls.add((title: title, body: body));
    if (nextError != null) {
      final ForumApiException err = nextError!;
      nextError = null;
      throw err;
    }
    return ForumCreatePostResponse(
      post: ForumPost(
        id: 'post-${calls.length}',
        authorId: 'profile-x',
        title: title,
        body: body,
        createdAt: _fixedNow,
        updatedAt: _fixedNow,
        voteCount: 0,
        hidden: false,
      ),
      crisisResources: crisisResources,
    );
  }

  // Stub out listPosts so the keepAlive CommunityFeed notifier doesn't
  // blow up when post_compose_screen calls refresh().
  @override
  Future<List<ForumPost>> listPosts({
    ForumPostSort sort = ForumPostSort.hot,
    String? before,
    int? limit,
  }) async => const <ForumPost>[];
}

GoRouter _router() {
  return GoRouter(
    initialLocation: '/compose',
    routes: <RouteBase>[
      GoRoute(
        path: '/compose',
        name: 'community-compose',
        builder: (_, __) => const PostComposeScreen(),
      ),
      GoRoute(
        path: '/community',
        name: 'community',
        builder: (_, __) => const _StubFeed(),
      ),
      GoRoute(
        path: '/community/guidelines',
        name: 'community-guidelines',
        builder: (_, __) => Scaffold(
          appBar: AppBar(title: const Text('Community guidelines')),
          body: const Text('GUIDELINES'),
        ),
      ),
    ],
  );
}

class _StubFeed extends StatelessWidget {
  const _StubFeed();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('FEED'));
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeForumApiClient client,
  bool alreadyAcknowledged = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (alreadyAcknowledged) guidelinesAcknowledgedPrefsKey: true,
  });
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(client),
      ],
      // The first-post ack modal embeds CommunityGuidelinesScreen.embedded(),
      // which reads AppLocalizations.of(context) after the #18 localization
      // conversion. Register the generated delegate + supportedLocales here
      // (as lib/app.dart does) so opening the modal doesn't throw on a
      // missing Localizations scope.
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: _router(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('PostComposeScreen — BUILD_SPEC.md §13 / Phase 13.12', () {
    testWidgets('renders title + body fields with live counters',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient();
      await _pump(tester, client: client);

      expect(find.byKey(PostComposeScreen.titleFieldKey), findsOneWidget);
      expect(find.byKey(PostComposeScreen.bodyFieldKey), findsOneWidget);
      expect(
        find.byKey(PostComposeScreen.titleCounterKey),
        findsOneWidget,
      );
      expect(find.byKey(PostComposeScreen.bodyCounterKey), findsOneWidget);

      await tester.enterText(
        find.byKey(PostComposeScreen.titleFieldKey),
        'Hello',
      );
      await tester.pump();
      final Text counter = tester
          .widget<Text>(find.byKey(PostComposeScreen.titleCounterKey));
      expect(counter.data, '5 / 200');
    });

    testWidgets(
        'empty submit is tappable and highlights both missing fields',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient();
      await _pump(tester, client: client, alreadyAcknowledged: true);

      // The Post button is ALWAYS tappable (no greyed-out mystery) —
      // pressing it on an empty form validates and surfaces the inline
      // "Add a title" / "Add some detail" errors instead of POSTing.
      await tester.tap(find.byKey(PostComposeScreen.submitButtonKey));
      await tester.pumpAndSettle();
      expect(client.calls, isEmpty,
          reason: 'empty submit must not POST');
      expect(find.text('Add a title — even a few words helps.'),
          findsOneWidget);
      expect(find.text('Add some detail — tell us the moment.'),
          findsOneWidget);

      // Title only — body error persists, still no POST.
      await tester.enterText(
        find.byKey(PostComposeScreen.titleFieldKey),
        'Title only',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PostComposeScreen.submitButtonKey));
      await tester.pumpAndSettle();
      expect(client.calls, isEmpty,
          reason: 'submit must require non-empty body');
      expect(find.text('Add some detail — tell us the moment.'),
          findsOneWidget);
    });

    testWidgets(
        'first submit opens the ack modal; cancel keeps the draft + skips API',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient();
      await _pump(tester, client: client);

      await tester.enterText(
        find.byKey(PostComposeScreen.titleFieldKey),
        'My first post',
      );
      await tester.enterText(
        find.byKey(PostComposeScreen.bodyFieldKey),
        'A real moment from this week.',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(PostComposeScreen.submitButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(PostComposeScreen.ackSheetKey), findsOneWidget,
          reason: 'first-post ack modal must open');

      await tester.tap(find.byKey(PostComposeScreen.ackCancelKey));
      await tester.pumpAndSettle();
      expect(find.byKey(PostComposeScreen.ackSheetKey), findsNothing);
      expect(client.calls, isEmpty,
          reason: 'cancel must not POST');
      // Draft survives — fields still populated.
      final TextFormField title = tester
          .widget<TextFormField>(find.byKey(PostComposeScreen.titleFieldKey));
      expect(title.controller!.text, 'My first post');
    });

    testWidgets('accepting the ack modal posts + flips the persisted flag',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient();
      await _pump(tester, client: client);

      await tester.enterText(
        find.byKey(PostComposeScreen.titleFieldKey),
        'My first post',
      );
      await tester.enterText(
        find.byKey(PostComposeScreen.bodyFieldKey),
        'A real moment from this week.',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(PostComposeScreen.submitButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(PostComposeScreen.ackSheetKey), findsOneWidget);

      await tester.tap(find.byKey(PostComposeScreen.ackAcceptKey));
      await tester.pumpAndSettle();

      expect(client.calls, hasLength(1));
      expect(client.calls.first.title, 'My first post');

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(guidelinesAcknowledgedPrefsKey), isTrue);
    });

    testWidgets(
        'second submit (already acknowledged) posts directly without modal',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient();
      await _pump(tester, client: client, alreadyAcknowledged: true);

      await tester.enterText(
        find.byKey(PostComposeScreen.titleFieldKey),
        'Second time around',
      );
      await tester.enterText(
        find.byKey(PostComposeScreen.bodyFieldKey),
        'Returning post.',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(PostComposeScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(PostComposeScreen.ackSheetKey), findsNothing,
          reason: 'modal must NOT open when already acknowledged');
      expect(client.calls, hasLength(1));
    });

    testWidgets('surface a human error banner on Worker 429',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient()
        ..nextError = ForumApiException(
          statusCode: 429,
          error: 'rate_limited',
        );
      await _pump(tester, client: client, alreadyAcknowledged: true);

      await tester.enterText(
        find.byKey(PostComposeScreen.titleFieldKey),
        'Title',
      );
      await tester.enterText(
        find.byKey(PostComposeScreen.bodyFieldKey),
        'Body',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(PostComposeScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(PostComposeScreen.errorBannerKey), findsOneWidget);
      expect(
        find.textContaining("posted recently"),
        findsOneWidget,
      );
    });
  });
}

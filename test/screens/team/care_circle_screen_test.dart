import 'package:careblazers/models/forum.dart';
import 'package:careblazers/providers/my_forum_profile_provider.dart';
import 'package:careblazers/screens/team/care_circle_screen.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// Recording stub for the Invite-by-link path: a circle already exists
/// (so the screen never needs `myForumProfileProvider`), and
/// [createInvite] hands back a fixed token. [baseUrl] is the forum origin
/// WITHOUT the /api/v1 suffix — the link is built off it.
class _RecordingForumClient extends ForumApiClient {
  _RecordingForumClient({this.baseUrlValue = 'https://forum.example.test'})
      : super(
          tokenLoader: _stub,
          baseUrl: baseUrlValue,
        );

  static Future<String> _stub() async => 'stub-token';

  final String baseUrlValue;
  int createInviteCalls = 0;

  static final CircleDto _circle = CircleDto(
    id: 'c1',
    name: 'Sarah\'s circle',
    ownerProfileId: 'p1',
    createdAt: DateTime(2026, 1, 1),
  );

  @override
  Future<List<CircleDto>> listCircles() async => <CircleDto>[_circle];

  @override
  Future<CircleInviteDto> createInvite(String circleId) async {
    createInviteCalls++;
    return CircleInviteDto(
      token: 'tok_link_123',
      circleId: circleId,
      expiresAt: DateTime(2026, 1, 8),
    );
  }
}

CircleMemberDto _member({
  required String profileId,
  String? username,
  String displayName = 'Sarah Henderson',
  String role = 'member',
}) =>
    CircleMemberDto(
      profileId: profileId,
      username: username,
      displayName: displayName,
      role: role,
    );

GoRouter _router() {
  return GoRouter(
    initialLocation: '/team/circle',
    routes: <RouteBase>[
      GoRoute(
        path: '/team',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST /team'))),
      ),
      GoRoute(
        path: '/team/circle',
        builder: (BuildContext c, GoRouterState s) => const CareCircleScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'username',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('DEST username'))),
          ),
          GoRoute(
            path: 'qr',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('DEST qr'))),
          ),
          GoRoute(
            path: 'scan',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('DEST scan'))),
          ),
        ],
      ),
    ],
  );
}

Future<GoRouter> _pump(
  WidgetTester tester, {
  required List<CircleMemberDto> members,
  String? myProfileId,
  ForumApiClient? client,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = _router();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        syncedCircleMembersProvider.overrideWith(
          (Ref ref) => Stream<List<CircleMemberDto>>.value(members),
        ),
        if (myProfileId != null)
          myForumProfileIdProvider.overrideWithValue(myProfileId),
        if (client != null) forumApiClientProvider.overrideWithValue(client),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.last.matchedLocation;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CareCircleScreen — People list (backend members)', () {
    testWidgets('renders synced members by @username, no pending tag',
        (WidgetTester tester) async {
      await _pump(
        tester,
        members: <CircleMemberDto>[
          _member(
            profileId: 'p1',
            username: 'sarah_h',
            displayName: 'Sarah Henderson',
            role: 'owner',
          ),
          _member(
            profileId: 'p2',
            username: 'james_h',
            displayName: 'James Henderson',
          ),
        ],
      );

      expect(find.byKey(CareCircleScreen.rowKey('p1')), findsOneWidget);
      expect(find.byKey(CareCircleScreen.rowKey('p2')), findsOneWidget);
      expect(find.text('@sarah_h'), findsOneWidget);
      expect(find.text('@james_h'), findsOneWidget);
      // Owner is badged; nobody is "Invite pending".
      expect(find.text('Owner'), findsOneWidget);
      expect(find.textContaining('Invite pending'), findsNothing);
      // Not the empty state.
      expect(find.byKey(CareCircleScreen.emptyStateKey), findsNothing);
    });

    testWidgets('falls back to display name when a member has no @username',
        (WidgetTester tester) async {
      await _pump(
        tester,
        members: <CircleMemberDto>[
          _member(profileId: 'p1', username: null, displayName: 'Maria Lopez'),
        ],
      );

      expect(find.text('Maria Lopez'), findsOneWidget);
    });

    testWidgets('badges the signed-in member as "You"',
        (WidgetTester tester) async {
      await _pump(
        tester,
        myProfileId: 'p1',
        members: <CircleMemberDto>[
          _member(profileId: 'p1', username: 'me_h', role: 'owner'),
          _member(profileId: 'p2', username: 'them_h'),
        ],
      );

      expect(find.text('You'), findsOneWidget);
    });
  });

  group('CareCircleScreen — empty / unconfigured', () {
    testWidgets(
        'shows the placeholder + connect actions when no one else is in '
        'the circle', (WidgetTester tester) async {
      final GoRouter router =
          await _pump(tester, members: const <CircleMemberDto>[]);

      expect(find.byKey(CareCircleScreen.emptyStateKey), findsOneWidget);
      expect(
        find.textContaining('No one else in your circle yet'),
        findsOneWidget,
      );
      // No pending rows ever.
      expect(find.textContaining('Invite pending'), findsNothing);

      // The connect actions are present and route correctly.
      expect(find.byKey(CareCircleScreen.usernameActionKey), findsOneWidget);
      expect(find.byKey(CareCircleScreen.showQrActionKey), findsOneWidget);
      expect(find.byKey(CareCircleScreen.scanActionKey), findsOneWidget);
      expect(
        find.byKey(CareCircleScreen.addByUsernameActionKey),
        findsOneWidget,
      );

      await tester.tap(find.byKey(CareCircleScreen.usernameActionKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/team/circle/username');
    });

    testWidgets('Show my QR routes to the QR screen',
        (WidgetTester tester) async {
      final GoRouter router =
          await _pump(tester, members: const <CircleMemberDto>[]);

      await tester.tap(find.byKey(CareCircleScreen.showQrActionKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/team/circle/qr');
    });

    testWidgets('Scan to add routes to the scan screen',
        (WidgetTester tester) async {
      final GoRouter router =
          await _pump(tester, members: const <CircleMemberDto>[]);

      await tester.tap(find.byKey(CareCircleScreen.scanActionKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/team/circle/scan');
    });
  });

  group('CareCircleScreen — Invite by link', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    Future<void> Function(String) original = shareCircleInvite;
    setUp(() => original = shareCircleInvite);
    tearDown(() => shareCircleInvite = original);

    testWidgets(
        'mints an invite + shares the <origin>/join/<token> link', (
      WidgetTester tester,
    ) async {
      final _RecordingForumClient client = _RecordingForumClient();
      final List<String> shared = <String>[];
      shareCircleInvite = (String message) async => shared.add(message);

      await _pump(
        tester,
        members: const <CircleMemberDto>[],
        client: client,
      );

      expect(
        find.byKey(CareCircleScreen.inviteByLinkActionKey),
        findsOneWidget,
      );
      await tester.tap(find.byKey(CareCircleScreen.inviteByLinkActionKey));
      await tester.pumpAndSettle();

      expect(client.createInviteCalls, 1);
      expect(shared, hasLength(1));
      // The shared message carries the warm copy + the full link built
      // off the backend origin + the minted token.
      expect(
        shared.single,
        'Join my care circle on Careblazers: '
        'https://forum.example.test/join/tok_link_123',
      );
    });

    testWidgets('degrades calmly when there is no backend origin', (
      WidgetTester tester,
    ) async {
      final _RecordingForumClient client =
          _RecordingForumClient(baseUrlValue: '');
      final List<String> shared = <String>[];
      shareCircleInvite = (String message) async => shared.add(message);

      await _pump(
        tester,
        members: const <CircleMemberDto>[],
        client: client,
      );

      await tester.tap(find.byKey(CareCircleScreen.inviteByLinkActionKey));
      await tester.pumpAndSettle();

      // No invite minted, no share — just a calm SnackBar.
      expect(client.createInviteCalls, 0);
      expect(shared, isEmpty);
      expect(
        find.textContaining('Connect to share an invite link'),
        findsOneWidget,
      );
    });
  });
}

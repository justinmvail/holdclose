import 'package:holdclose/models/forum.dart';
import 'package:holdclose/providers/share_provider.dart';
import 'package:holdclose/screens/team/circle_qr_screen.dart';
import 'package:holdclose/services/fake_forum_api_client.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Recording stub for the Share-link path: a circle already exists (so the
/// screen never needs `myForumProfileProvider`), and [createInvite] mints
/// SEQUENTIAL tokens (`tok_1`, `tok_2`, …) so a test can tell the QR's
/// token apart from the fresh one the share action must mint. [baseUrl] is
/// the forum origin WITHOUT the /api/v1 suffix — the link is built off it.
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
    name: "Sarah's circle",
    ownerProfileId: 'p1',
    createdAt: DateTime(2026, 1, 1),
  );

  @override
  Future<List<CircleDto>> listCircles() async => <CircleDto>[_circle];

  @override
  Future<CircleInviteDto> createInvite(String circleId) async {
    createInviteCalls++;
    return CircleInviteDto(
      token: 'tok_$createInviteCalls',
      circleId: circleId,
      expiresAt: DateTime(2026, 1, 3),
    );
  }
}

GoRouter _router() => GoRouter(
      initialLocation: '/team/circle/qr',
      routes: <RouteBase>[
        GoRoute(
          path: '/team/circle',
          builder: (BuildContext c, GoRouterState s) =>
              const Scaffold(body: Text('DEST circle')),
          routes: <RouteBase>[
            GoRoute(
              path: 'qr',
              builder: (BuildContext c, GoRouterState s) =>
                  const CircleQrScreen(),
            ),
          ],
        ),
      ],
    );

Future<void> _pump(
  WidgetTester tester,
  ForumApiClient client, {
  Sharer? sharer,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(client),
        if (sharer != null) sharerProvider.overrideWithValue(sharer),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders a QrImageView for the minted invite token',
      (tester) async {
    await _pump(tester, FakeForumApiClient());

    final Finder qr = find.byKey(CircleQrScreen.qrKey);
    expect(qr, findsOneWidget);
    expect(tester.widget<QrImageView>(qr), isA<QrImageView>());
    expect(find.text('This code is valid for 2 days.'), findsOneWidget);
  });

  test('circleQrPayload prefixes the token with the scheme', () {
    expect(circleQrPayload('abc'), 'holdclose:circle:abc');
  });

  group('CircleQrScreen — Share link', () {
    testWidgets(
        'mints a FRESH invite and shares the <origin>/join/<token> URL', (
      WidgetTester tester,
    ) async {
      final _RecordingForumClient client = _RecordingForumClient();
      final RecordingSharer sharer = RecordingSharer();
      await _pump(tester, client, sharer: sharer);

      // The on-screen QR consumed the first minted token (`tok_1`).
      expect(client.createInviteCalls, 1);

      await tester.ensureVisible(find.byKey(CircleQrScreen.shareLinkKey));
      await tester.tap(find.byKey(CircleQrScreen.shareLinkKey));
      await tester.pumpAndSettle();

      // Invites are single-use, so the share must NOT reuse the QR's
      // token — a second, fresh invite backs the shared landing URL.
      expect(client.createInviteCalls, 2);
      expect(sharer.shared, hasLength(1));
      expect(
        sharer.shared.single.text,
        'Join my care circle on Holdclose: '
        'https://forum.example.test/join/tok_2',
      );
    });

    testWidgets('degrades calmly when there is no backend origin', (
      WidgetTester tester,
    ) async {
      final _RecordingForumClient client =
          _RecordingForumClient(baseUrlValue: '');
      final RecordingSharer sharer = RecordingSharer();
      await _pump(tester, client, sharer: sharer);

      await tester.ensureVisible(find.byKey(CircleQrScreen.shareLinkKey));
      await tester.tap(find.byKey(CircleQrScreen.shareLinkKey));
      await tester.pumpAndSettle();

      // Only the QR's own mint — no share invite, no share sheet, just a
      // calm SnackBar pointing back at the QR.
      expect(client.createInviteCalls, 1);
      expect(sharer.shared, isEmpty);
      expect(
        find.textContaining('Connect to share an invite link'),
        findsOneWidget,
      );
    });
  });
}

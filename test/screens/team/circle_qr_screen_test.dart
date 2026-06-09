import 'package:careblazers/screens/team/circle_qr_screen.dart';
import 'package:careblazers/services/fake_forum_api_client.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

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

Future<void> _pump(WidgetTester tester, ForumApiClient client) async {
  await tester.binding.setSurfaceSize(const Size(440, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(client),
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
    expect(find.text('This code is valid for 7 days.'), findsOneWidget);
  });

  test('circleQrPayload prefixes the token with the scheme', () {
    expect(circleQrPayload('abc'), 'careblazers:circle:abc');
  });
}

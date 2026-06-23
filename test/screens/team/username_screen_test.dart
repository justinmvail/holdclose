import 'package:holdclose/services/fake_forum_api_client.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:holdclose/screens/team/username_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// A fake whose username availability check can be steered per-handle so
/// the screen's available / taken / invalid states are all reachable
/// without a network.
class _SteerableForumClient extends FakeForumApiClient {
  _SteerableForumClient();

  final Set<String> taken = <String>{};

  @override
  Future<({bool valid, bool available})> usernameAvailable(
    String handle,
  ) async {
    final RegExp pattern = RegExp(r'^[a-z0-9_]{3,20}$');
    if (!pattern.hasMatch(handle.toLowerCase())) {
      return (valid: false, available: false);
    }
    return (valid: true, available: !taken.contains(handle.toLowerCase()));
  }
}

GoRouter _router() => GoRouter(
      initialLocation: '/team/circle/username',
      routes: <RouteBase>[
        GoRoute(
          path: '/team/circle',
          builder: (BuildContext c, GoRouterState s) =>
              const Scaffold(body: Text('DEST circle')),
          routes: <RouteBase>[
            GoRoute(
              path: 'username',
              builder: (BuildContext c, GoRouterState s) =>
                  const UsernameScreen(),
            ),
          ],
        ),
      ],
    );

Future<void> _pump(WidgetTester tester, ForumApiClient client) async {
  await tester.binding.setSurfaceSize(const Size(440, 1200));
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
  testWidgets('shows "Available" for a free, valid handle', (tester) async {
    await _pump(tester, _SteerableForumClient());

    await tester.enterText(find.byKey(UsernameScreen.fieldKey), 'sarah_h');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Available'), findsOneWidget);
    // Save is enabled when available.
    final ElevatedButton save = tester.widget<ElevatedButton>(
      find.byKey(UsernameScreen.saveKey),
    );
    expect(save.onPressed, isNotNull);
  });

  testWidgets('shows "Taken" for a claimed handle', (tester) async {
    final _SteerableForumClient client = _SteerableForumClient()
      ..taken.add('admin');
    await _pump(tester, client);

    await tester.enterText(find.byKey(UsernameScreen.fieldKey), 'admin');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Taken'), findsOneWidget);
    final ElevatedButton save = tester.widget<ElevatedButton>(
      find.byKey(UsernameScreen.saveKey),
    );
    expect(save.onPressed, isNull, reason: 'cannot save a taken handle');
  });

  testWidgets('shows invalid for a too-short handle', (tester) async {
    await _pump(tester, _SteerableForumClient());

    await tester.enterText(find.byKey(UsernameScreen.fieldKey), 'ab');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Not a valid username'), findsOneWidget);
  });

  testWidgets('Save persists the handle through updateMyProfile',
      (tester) async {
    final FakeForumApiClient client = FakeForumApiClient();
    await _pump(tester, client);

    await tester.enterText(find.byKey(UsernameScreen.fieldKey), 'newname');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Available'), findsOneWidget);

    await tester.tap(find.byKey(UsernameScreen.saveKey));
    await tester.pumpAndSettle();

    // The fake now holds the handle.
    final ({bool valid, bool available}) after =
        await client.usernameAvailable('newname');
    expect(after.available, isTrue,
        reason: 'the caller still owns the handle they just claimed');
    expect((await client.getMyProfile()).username, 'newname');
  });
}

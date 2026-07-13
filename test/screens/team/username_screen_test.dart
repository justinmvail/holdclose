import 'dart:io';

import 'package:holdclose/providers/photo_attacher_provider.dart';
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

/// A [PhotoAttacher] that returns a caller-supplied path (or null to model
/// the caregiver cancelling the OS picker).
class _StubPhotoAttacher implements PhotoAttacher {
  _StubPhotoAttacher(this.path);

  final String? path;
  int calls = 0;

  @override
  Future<String?> pickPhoto({
    PhotoSource source = PhotoSource.library,
    int maxSide = 2048,
    int quality = 80,
  }) async {
    calls++;
    return path;
  }
}

Future<void> _pump(
  WidgetTester tester,
  ForumApiClient client, {
  PhotoAttacher? photos,
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(client),
        if (photos != null) photoAttacherProvider.overrideWithValue(photos),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Write a real (tiny) file so the screen's `File(path).readAsBytes()` has
/// something to read — the upload path is exercised for real, not stubbed out.
File _tempPhoto() {
  final Directory dir = Directory.systemTemp.createTempSync('hc_avatar_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final File file = File('${dir.path}/photo.jpg');
  file.writeAsBytesSync(<int>[1, 2, 3, 4]);
  return file;
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

  testWidgets('Add photo → picks → uploads → the avatar and label update',
      (tester) async {
    // The avatar feature was dead end-to-end until 2026-07-13 (no upload
    // route, and R2_PUBLIC_URL pointed at a domain that resolved nowhere).
    // This pins the app half: pick → real bytes → uploadAvatar → refresh.
    final FakeForumApiClient client = FakeForumApiClient();
    final _StubPhotoAttacher photos = _StubPhotoAttacher(_tempPhoto().path);
    await _pump(tester, client, photos: photos);

    expect((await client.getMyProfile()).avatarUrl, isNull);
    expect(find.text('Add photo'), findsOneWidget);

    // runAsync: the screen does REAL file IO (`File(path).readAsBytes()`),
    // which never completes inside testWidgets' fake-async zone.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(UsernameScreen.photoButtonKey));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    // Deliberately NOT pumpAndSettle: with an avatar_url set, ForumAvatar
    // mounts an Image.network, and flutter_test's stub HttpClient leaves that
    // request pending forever — pumpAndSettle would spin until it timed out.
    // (The widget copes: loadingBuilder holds the initial until it resolves.)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(photos.calls, 1);
    // The photo actually landed on the profile...
    expect((await client.getMyProfile()).avatarUrl, isNotNull);
    // ...and the screen now offers to CHANGE it rather than add one.
    expect(find.text('Change photo'), findsOneWidget);
    expect(find.text('Add photo'), findsNothing);
    expect(find.text('Your photo is updated.'), findsOneWidget);
  });

  testWidgets('cancelling the picker uploads nothing', (tester) async {
    final FakeForumApiClient client = FakeForumApiClient();
    final _StubPhotoAttacher photos = _StubPhotoAttacher(null); // cancelled
    await _pump(tester, client, photos: photos);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(UsernameScreen.photoButtonKey));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(photos.calls, 1);
    expect((await client.getMyProfile()).avatarUrl, isNull);
    expect(find.text('Add photo'), findsOneWidget);
  });
}

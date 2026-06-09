import 'dart:async';

import 'package:careblazers/models/forum.dart';
import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/services/circle_deep_link_handler.dart';
import 'package:careblazers/services/circle_invite_link.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Auth stub that emits a single state (signed-in or signed-out) on
/// subscribe — the handler only reads `watchAuthState().first`.
class _AuthStub implements AuthProvider {
  _AuthStub({required this.signedIn});
  final bool signedIn;

  static const User _user = User(
    id: 'u1',
    email: 'c@careblazers.app',
    name: 'Caregiver',
  );

  @override
  Stream<AuthState> watchAuthState() async* {
    yield signedIn
        ? const AuthState.signedIn(user: _user)
        : const AuthState.signedOut();
  }

  @override
  Future<void> signInWithApple() async {}
  @override
  Future<void> signInWithGoogle() async {}
  @override
  Future<void> signOut() async {}
  @override
  Future<void> deleteAccount() async {}
}

/// Recording forum client: [joinCircle] returns a circle for a known good
/// token and throws [ForumApiException] for the expired one.
class _RecordingClient extends ForumApiClient {
  _RecordingClient() : super(tokenLoader: _stub, baseUrl: 'https://x.test');
  static Future<String> _stub() async => 't';

  final List<String> joinedTokens = <String>[];

  static final CircleDto circle = CircleDto(
    id: 'c1',
    name: 'Mary\'s circle',
    ownerProfileId: 'p1',
    createdAt: DateTime(2026, 1, 1),
  );

  @override
  Future<CircleDto> joinCircle(String token) async {
    joinedTokens.add(token);
    if (token == 'expired') {
      throw ForumApiException(statusCode: 410, error: 'invite_expired');
    }
    if (token == 'bad') {
      throw ForumApiException(statusCode: 404, error: 'invite_not_found');
    }
    return circle;
  }
}

ProviderContainer _container({
  required bool signedIn,
  required _RecordingClient client,
  List<CircleDto>? adopted,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      authBackendProvider.overrideWithValue(_AuthStub(signedIn: signedIn)),
      forumApiClientProvider.overrideWithValue(client),
      circleAdoptProvider.overrideWithValue(
        (CircleDto c) async => adopted?.add(c),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('parseCircleInviteToken', () {
    test('parses the link-style careblazers://join/<token>', () {
      expect(
        parseCircleInviteTokenFromString('careblazers://join/abc123'),
        'abc123',
      );
    });

    test('parses the QR-style careblazers:circle:<token>', () {
      expect(
        parseCircleInviteTokenFromString('careblazers:circle:xyz789'),
        'xyz789',
      );
    });

    test('returns null for an unrelated / empty URI', () {
      expect(parseCircleInviteTokenFromString('https://example.com'), isNull);
      expect(parseCircleInviteTokenFromString('careblazers://join/'), isNull);
      expect(parseCircleInviteTokenFromString(null), isNull);
    });

    test('circleInviteLink joins origin + token, trimming a trailing slash',
        () {
      expect(
        circleInviteLink(origin: 'https://h.test/', token: 'tok'),
        'https://h.test/join/tok',
      );
    });
  });

  group('CircleDeepLinkHandler', () {
    test('valid token while signed in → joins + adopts + succeeds', () async {
      final client = _RecordingClient();
      final adopted = <CircleDto>[];
      final container =
          _container(signedIn: true, client: client, adopted: adopted);
      final handler = container.read(circleDeepLinkHandlerProvider);

      final outcome =
          await handler.handleUri('careblazers://join/good_token');

      expect(outcome, isA<CircleJoinSucceeded>());
      expect((outcome as CircleJoinSucceeded).circle.name, 'Mary\'s circle');
      expect(client.joinedTokens, <String>['good_token']);
      // Adopt is fire-and-forget — let its microtask run.
      await Future<void>.delayed(Duration.zero);
      expect(adopted, hasLength(1));
    });

    test('expired token → CircleJoinFailed, no crash', () async {
      final client = _RecordingClient();
      final container = _container(signedIn: true, client: client);
      final handler = container.read(circleDeepLinkHandlerProvider);

      final outcome = await handler.handleUri('careblazers://join/expired');

      expect(outcome, isA<CircleJoinFailed>());
      expect((outcome as CircleJoinFailed).message, contains('expired'));
    });

    test('invalid token → CircleJoinFailed', () async {
      final client = _RecordingClient();
      final container = _container(signedIn: true, client: client);
      final handler = container.read(circleDeepLinkHandlerProvider);

      final outcome = await handler.handleUri('careblazers://join/bad');

      expect(outcome, isA<CircleJoinFailed>());
    });

    test('non-link URI → CircleJoinNotALink, never calls join', () async {
      final client = _RecordingClient();
      final container = _container(signedIn: true, client: client);
      final handler = container.read(circleDeepLinkHandlerProvider);

      final outcome = await handler.handleUri('https://example.com/foo');

      expect(outcome, isA<CircleJoinNotALink>());
      expect(client.joinedTokens, isEmpty);
    });

    test('signed out → stashes, then processes on sign-in', () async {
      final client = _RecordingClient();
      final adopted = <CircleDto>[];
      final container =
          _container(signedIn: false, client: client, adopted: adopted);
      final handler = container.read(circleDeepLinkHandlerProvider);

      final stashed = await handler.handleUri('careblazers://join/good_token');
      expect(stashed, isA<CircleJoinStashed>());
      expect(client.joinedTokens, isEmpty);
      expect(handler.hasPending, isTrue);

      // Sign-in lands → replay the stashed token.
      final replayed = await handler.processPending();
      expect(replayed, isA<CircleJoinSucceeded>());
      expect(client.joinedTokens, <String>['good_token']);
      expect(handler.hasPending, isFalse);

      // Nothing left to process.
      expect(await handler.processPending(), isNull);
    });
  });
}

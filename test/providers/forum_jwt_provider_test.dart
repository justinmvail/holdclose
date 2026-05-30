import 'dart:convert';

import 'package:careblazers/providers/forum_jwt_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---- ForumSecretStore ---------------------------------------------------

  group('ForumSecretStore — Phase 13.9 secure-storage seeding', () {
    const MethodChannel channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final Map<String, String> store = <String, String>{};
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      store.clear();
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        final Map<dynamic, dynamic> args =
            (call.arguments as Map<dynamic, dynamic>?) ??
                <dynamic, dynamic>{};
        final String? key = args['key'] as String?;
        switch (call.method) {
          case 'write':
            if (key != null) store[key] = args['value'] as String? ?? '';
            return null;
          case 'read':
            return store[key];
          case 'delete':
            if (key != null) store.remove(key);
            return null;
          case 'containsKey':
            return store.containsKey(key);
          case 'deleteAll':
            store.clear();
            return null;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('seeds from the compile-time define on first load', () async {
      final ForumSecretStore secretStore = ForumSecretStore(
        storage: const FlutterSecureStorage(),
        compileTimeSecret: 'super-secret-build-define',
      );
      final String loaded = await secretStore.load();
      expect(loaded, 'super-secret-build-define');
      expect(store[forumSecretStorageKey], 'super-secret-build-define');
    });

    test('subsequent loads come from secure storage, NOT the define',
        () async {
      store[forumSecretStorageKey] = 'rotated-via-out-of-band-write';
      final ForumSecretStore secretStore = ForumSecretStore(
        storage: const FlutterSecureStorage(),
        compileTimeSecret: 'should-not-be-used',
      );
      final String loaded = await secretStore.load();
      expect(loaded, 'rotated-via-out-of-band-write');
      // No write call — already-cached value should not re-seed.
      expect(calls.where((MethodCall c) => c.method == 'write'), isEmpty);
    });

    test('throws StateError when neither secure storage nor the define '
        'carry a value', () async {
      final ForumSecretStore secretStore = ForumSecretStore(
        storage: const FlutterSecureStorage(),
        compileTimeSecret: '',
      );
      await expectLater(secretStore.load(), throwsStateError);
    });
  });

  // ---- ForumJwtMinter -----------------------------------------------------

  group('ForumJwtMinter — Phase 13.9 HS256 + refresh', () {
    const String secret = 'shared-secret-the-worker-also-knows';
    const String userId = 'careblazers-user-42';
    final DateTime baseTime = DateTime.utc(2026, 5, 30, 12);

    DateTime Function() fixedClock() => () => baseTime;

    ForumJwtMinter buildMinter({
      DateTime Function()? clock,
      ForumUserIdLoader? userIdLoader,
      Duration ttl = const Duration(hours: 1),
      Duration refreshThreshold = const Duration(minutes: 5),
    }) {
      return ForumJwtMinter(
        secretLoader: () async => secret,
        userIdLoader: userIdLoader ?? (() async => userId),
        ttl: ttl,
        refreshThreshold: refreshThreshold,
        clock: clock ?? fixedClock(),
      );
    }

    test('produces a 3-segment HS256 JWT', () async {
      final ForumJwtMinter minter = buildMinter();
      final String token = await minter.currentToken();
      final List<String> segments = token.split('.');
      expect(segments, hasLength(3));
      // Header decodes to {alg: HS256, typ: JWT}.
      final Map<String, dynamic> header =
          json.decode(utf8.decode(_b64uDecode(segments[0])))
              as Map<String, dynamic>;
      expect(header['alg'], 'HS256');
      expect(header['typ'], 'JWT');
    });

    test('signs payload {sub, iat, exp} matching the clock + ttl', () async {
      final ForumJwtMinter minter = buildMinter(
        ttl: const Duration(minutes: 30),
      );
      final String token = await minter.currentToken();
      final List<String> segments = token.split('.');
      final Map<String, dynamic> payload =
          json.decode(utf8.decode(_b64uDecode(segments[1])))
              as Map<String, dynamic>;
      expect(payload['sub'], userId);
      expect(
        payload['iat'],
        baseTime.millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        payload['exp'],
        baseTime.add(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('signature verifies under the shared secret', () async {
      final ForumJwtMinter minter = buildMinter();
      final String token = await minter.currentToken();
      final List<String> segments = token.split('.');
      final String signingInput = '${segments[0]}.${segments[1]}';
      final Digest expected =
          Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(signingInput));
      final List<int> actualBytes = _b64uDecode(segments[2]);
      expect(actualBytes, expected.bytes);
    });

    test('reuses the cached token while it is far from expiry', () async {
      final ForumJwtMinter minter = buildMinter();
      final String first = await minter.currentToken();
      final String second = await minter.currentToken();
      expect(identical(first, second), isTrue);
    });

    test('mints a fresh token when the cached one is inside the '
        'refresh threshold', () async {
      // Use a mutable clock so the second call lands inside the
      // refresh window.
      DateTime now = baseTime;
      final ForumJwtMinter minter = buildMinter(
        clock: () => now,
        ttl: const Duration(minutes: 10),
        refreshThreshold: const Duration(minutes: 2),
      );
      final String first = await minter.currentToken();
      // Jump to 9 minutes in — only 1 minute of TTL left, inside the
      // 2-minute refresh window.
      now = baseTime.add(const Duration(minutes: 9));
      final String second = await minter.currentToken();
      expect(second, isNot(equals(first)));
      // The new token's exp should be a fresh ttl beyond the new clock.
      final Map<String, dynamic> payload =
          json.decode(utf8.decode(_b64uDecode(second.split('.')[1])))
              as Map<String, dynamic>;
      expect(
        payload['exp'],
        now.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('invalidates the cache when the signed-in user changes', () async {
      String currentUser = 'first-user';
      final ForumJwtMinter minter = buildMinter(
        userIdLoader: () async => currentUser,
      );
      final String first = await minter.currentToken();
      currentUser = 'second-user';
      final String second = await minter.currentToken();
      expect(second, isNot(equals(first)));
      final Map<String, dynamic> payload =
          json.decode(utf8.decode(_b64uDecode(second.split('.')[1])))
              as Map<String, dynamic>;
      expect(payload['sub'], 'second-user');
    });

    test('throws StateError when no user is signed in', () async {
      final ForumJwtMinter minter = buildMinter(
        userIdLoader: () async => null,
      );
      await expectLater(minter.currentToken(), throwsStateError);
    });

    test('invalidate() forces the next call to mint fresh', () async {
      final ForumJwtMinter minter = buildMinter();
      final String first = await minter.currentToken();
      minter.invalidate();
      expect(minter.cachedExpiresAt, isNull);
      final String second = await minter.currentToken();
      // Same time, same user, same secret → token bytes are identical
      // even though the cache was cleared. Verify by checking the
      // minter actually re-signed (cache was repopulated).
      expect(minter.cachedExpiresAt, isNotNull);
      expect(second, equals(first));
    });

    test('refuses to sign when the secret loader returns an empty string',
        () async {
      final ForumJwtMinter minter = ForumJwtMinter(
        secretLoader: () async => '',
        userIdLoader: () async => userId,
      );
      await expectLater(minter.currentToken(), throwsStateError);
    });
  });
}

/// Decode a base64url segment, restoring `=` padding the JWT emitter
/// strips per RFC 7515 §2.
List<int> _b64uDecode(String segment) {
  final int rem = segment.length % 4;
  final String padded = rem == 0 ? segment : segment + '=' * (4 - rem);
  return base64Url.decode(padded);
}

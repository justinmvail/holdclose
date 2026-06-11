import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:careblazers/providers/forum_jwt_provider.dart';

/// In-memory [FlutterSecureStorage] stand-in. Only the members the
/// session store touches are overridden; everything else inherits the
/// (throwing) noSuchMethod from [Fake].
class _FakeSecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

ForumSession _session(String token, DateTime expiresAt) =>
    ForumSession(token: token, expiresAt: expiresAt);

void main() {
  final DateTime now = DateTime.utc(2026, 6, 11, 12);
  DateTime clock() => now;

  group('ForumSessionStore — secure-storage persistence', () {
    test('round-trips a session (token + epoch-seconds expiry)', () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      final ForumSessionStore store = ForumSessionStore(storage: storage);

      final DateTime expiry = DateTime.utc(2026, 7, 11);
      await store.write(_session('tok-123', expiry));
      final ForumSession? read = await store.read();

      expect(read, isNotNull);
      expect(read!.token, 'tok-123');
      expect(read.expiresAt, expiry);
    });

    test('returns null when nothing is stored or expiry is corrupt',
        () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      final ForumSessionStore store = ForumSessionStore(storage: storage);
      expect(await store.read(), isNull);

      storage.values[forumSessionTokenStorageKey] = 'tok';
      storage.values[forumSessionExpiryStorageKey] = 'not-a-number';
      expect(await store.read(), isNull);
    });

    test('write and clear both shed the LEGACY on-device signing secret',
        () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      storage.values[forumSecretStorageKey] = 'legacy-shared-secret';
      final ForumSessionStore store = ForumSessionStore(storage: storage);

      await store.write(_session('tok', DateTime.utc(2026, 7, 1)));
      expect(storage.values.containsKey(forumSecretStorageKey), isFalse);

      storage.values[forumSecretStorageKey] = 'legacy-shared-secret';
      await store.clear();
      expect(storage.values.containsKey(forumSecretStorageKey), isFalse);
      expect(storage.values.containsKey(forumSessionTokenStorageKey), isFalse);
      expect(
        storage.values.containsKey(forumSessionExpiryStorageKey),
        isFalse,
      );
    });
  });

  group('ForumSessionManager — token lifecycle', () {
    test('returns the stored token while it is far from expiry — '
        'no refresh call', () async {
      final ForumSessionStore store =
          ForumSessionStore(storage: _FakeSecureStorage());
      await store.write(_session('fresh', now.add(const Duration(days: 20))));
      int refreshes = 0;
      final ForumSessionManager manager = ForumSessionManager(
        store: store,
        refresher: () async {
          refreshes += 1;
          return null;
        },
        clock: clock,
      );

      expect(await manager.currentToken(), 'fresh');
      expect(refreshes, 0);
    });

    test('refreshes when inside the refresh-ahead window, '
        'persisting the new session', () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      final ForumSessionStore store = ForumSessionStore(storage: storage);
      await store.write(_session('aging', now.add(const Duration(days: 2))));
      final ForumSessionManager manager = ForumSessionManager(
        store: store,
        refresher: () async =>
            _session('renewed', now.add(const Duration(days: 30))),
        clock: clock,
      );

      expect(await manager.currentToken(), 'renewed');
      expect(storage.values[forumSessionTokenStorageKey], 'renewed');
    });

    test('falls back to the stored (still-valid) token when refresh fails',
        () async {
      final ForumSessionStore store =
          ForumSessionStore(storage: _FakeSecureStorage());
      await store.write(_session('aging', now.add(const Duration(days: 2))));
      final ForumSessionManager manager = ForumSessionManager(
        store: store,
        refresher: () async => null,
        clock: clock,
      );

      expect(await manager.currentToken(), 'aging');
    });

    test('refreshes when the stored token is expired', () async {
      final ForumSessionStore store =
          ForumSessionStore(storage: _FakeSecureStorage());
      await store
          .write(_session('dead', now.subtract(const Duration(hours: 1))));
      final ForumSessionManager manager = ForumSessionManager(
        store: store,
        refresher: () async =>
            _session('reborn', now.add(const Duration(days: 30))),
        clock: clock,
      );

      expect(await manager.currentToken(), 'reborn');
    });

    test('throws StateError when no token exists and refresh yields nothing',
        () async {
      final ForumSessionManager manager = ForumSessionManager(
        store: ForumSessionStore(storage: _FakeSecureStorage()),
        refresher: () async => null,
        clock: clock,
      );

      expect(manager.currentToken, throwsStateError);
    });

    test('a throwing refresher is swallowed — surfaces as StateError, '
        'not the refresher error', () async {
      final ForumSessionManager manager = ForumSessionManager(
        store: ForumSessionStore(storage: _FakeSecureStorage()),
        refresher: () async => throw Exception('network down'),
        clock: clock,
      );

      expect(manager.currentToken, throwsStateError);
    });

    test('concurrent expired-token calls share ONE refresh exchange',
        () async {
      int refreshes = 0;
      final ForumSessionManager manager = ForumSessionManager(
        store: ForumSessionStore(storage: _FakeSecureStorage()),
        refresher: () async {
          refreshes += 1;
          await Future<void>.delayed(Duration.zero);
          return _session('shared', now.add(const Duration(days: 30)));
        },
        clock: clock,
      );

      final List<String> tokens = await Future.wait(<Future<String>>[
        manager.currentToken(),
        manager.currentToken(),
        manager.currentToken(),
      ]);
      expect(tokens, everyElement('shared'));
      expect(refreshes, 1);
    });

    test('adoptSession caches + persists the sign-in token', () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      int refreshes = 0;
      final ForumSessionManager manager = ForumSessionManager(
        store: ForumSessionStore(storage: storage),
        refresher: () async {
          refreshes += 1;
          return null;
        },
        clock: clock,
      );

      await manager.adoptSession(
        _session('adopted', now.add(const Duration(days: 30))),
      );
      expect(await manager.currentToken(), 'adopted');
      expect(refreshes, 0);
      expect(storage.values[forumSessionTokenStorageKey], 'adopted');
    });

    test('recoverFromExpiry drops the dead token, re-exchanges, '
        'and reports success', () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      final ForumSessionStore store = ForumSessionStore(storage: storage);
      await store.write(
        _session('rejected-by-server', now.add(const Duration(days: 20))),
      );
      final ForumSessionManager manager = ForumSessionManager(
        store: store,
        refresher: () async =>
            _session('recovered', now.add(const Duration(days: 30))),
        clock: clock,
      );

      expect(await manager.recoverFromExpiry(), isTrue);
      expect(await manager.currentToken(), 'recovered');
    });

    test('recoverFromExpiry reports failure when no refresh is possible '
        '(and the dead token stays gone)', () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      final ForumSessionStore store = ForumSessionStore(storage: storage);
      await store.write(
        _session('rejected-by-server', now.add(const Duration(days: 20))),
      );
      final ForumSessionManager manager = ForumSessionManager(
        store: store,
        refresher: () async => null,
        clock: clock,
      );

      expect(await manager.recoverFromExpiry(), isFalse);
      expect(storage.values.containsKey(forumSessionTokenStorageKey), isFalse);
    });

    test('clear() (sign-out) forgets cache + storage', () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      final ForumSessionManager manager = ForumSessionManager(
        store: ForumSessionStore(storage: storage),
        refresher: () async => null,
        clock: clock,
      );
      await manager.adoptSession(
        _session('signed-in', now.add(const Duration(days: 30))),
      );

      await manager.clear();

      expect(storage.values, isEmpty);
      expect(manager.currentToken, throwsStateError);
    });
  });
}

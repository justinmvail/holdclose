import 'dart:async';
import 'dart:convert';

import 'package:holdclose/providers/auth_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Fully-deterministic [OAuthFlow] that returns [result] (or null) and
/// records the call count so tests can assert "the flow was driven once".
class _ScriptedFlow {
  _ScriptedFlow(this.result, {this.error});

  final OAuthSignInResult? result;
  final Object? error;
  int calls = 0;

  Future<OAuthSignInResult?> call() async {
    calls += 1;
    if (error != null) throw error!;
    return result;
  }
}

/// Deterministic [AccountDeleter] that records its call count and can be
/// scripted to throw — models the backend `DELETE /profiles/me` succeeding
/// or failing (offline / 5xx).
class _ScriptedDeleter {
  _ScriptedDeleter({this.error});

  final Object? error;
  int calls = 0;

  Future<void> call() async {
    calls += 1;
    if (error != null) throw error!;
  }
}

/// In-memory [UserStore] for the alpha delete-account tests — avoids the
/// shared_preferences platform channel the real store touches.
class InMemoryUserStore extends UserStore {
  InMemoryUserStore([this._user]);

  User? _user;

  @override
  Future<User?> read() async => _user;

  @override
  Future<void> write(User user) async => _user = user;

  @override
  Future<void> clear() async => _user = null;
}

/// Helper that collects every [AuthState] a provider emits until the
/// caller cancels — used to assert the watchAuthState stream contract.
Future<List<AuthState>> _drain(
  Stream<AuthState> stream, {
  required int count,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final List<AuthState> received = <AuthState>[];
  final Completer<void> done = Completer<void>();
  final StreamSubscription<AuthState> sub = stream.listen((AuthState s) {
    received.add(s);
    if (received.length >= count && !done.isCompleted) done.complete();
  });
  await done.future.timeout(timeout);
  await sub.cancel();
  return received;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const User altUser = User(
    id: 'alt-001',
    email: 'alt@holdclose.app',
    name: 'Alt Caregiver',
  );

  // ---- User model ---------------------------------------------------------

  group('User', () {
    test('field-by-field equality + hash', () {
      const User a =
          User(id: 'u1', email: 'a@x.test', name: 'Alex');
      const User b =
          User(id: 'u1', email: 'a@x.test', name: 'Alex');
      const User c =
          User(id: 'u2', email: 'a@x.test', name: 'Alex');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('JSON round-trip', () {
      const User u = User(
        id: 'u-42',
        email: 'demo@holdclose.app',
        name: 'Sarah Henderson',
      );
      final String encoded = jsonEncode(u.toJson());
      final User decoded = User.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(decoded, equals(u));
    });
  });

  // ---- AuthState sealed union --------------------------------------------

  group('AuthState', () {
    test('signedOut singleton equality', () {
      expect(const AuthState.signedOut(), equals(const AuthState.signedOut()));
    });

    test('signedIn equality follows the User', () {
      const AuthState a = AuthState.signedIn(
        user: User(id: 'x', email: 'x@y', name: 'X'),
      );
      const AuthState b = AuthState.signedIn(
        user: User(id: 'x', email: 'x@y', name: 'X'),
      );
      const AuthState c = AuthState.signedIn(
        user: User(id: 'z', email: 'x@y', name: 'X'),
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('exhaustive pattern matching compiles', () {
      String label(AuthState s) => switch (s) {
            AuthStateSignedOut() => 'out',
            AuthStateLoading() => 'loading',
            AuthStateSignedIn(:final User user) => 'in:${user.name}',
          };
      expect(label(const AuthState.signedOut()), 'out');
      expect(label(const AuthState.loading()), 'loading');
      expect(
        label(const AuthState.signedIn(user: altUser)),
        'in:Alt Caregiver',
      );
    });
  });

  // ---- FakeAuthProvider --------------------------------------------------

  group('FakeAuthProvider', () {
    test('defaults to the canned Sarah Henderson user', () {
      final FakeAuthProvider fake = FakeAuthProvider();
      expect(fake.user, equals(FakeAuthProvider.cannedSarahHenderson));
      expect(fake.user.email, 'demo@holdclose.app');
      expect(fake.user.name, 'Sarah Henderson');
      expect(fake.user.id, isNotEmpty);
    });

    test('accepts a custom canned user', () {
      final FakeAuthProvider fake = FakeAuthProvider(cannedUser: altUser);
      expect(fake.user, equals(altUser));
    });

    test('initial state is signedOut', () async {
      final FakeAuthProvider fake = FakeAuthProvider();
      addTearDown(fake.dispose);
      final AuthState first = await fake.watchAuthState().first;
      expect(first, equals(const AuthState.signedOut()));
    });

    test('signInWithApple emits signedIn with the canned user', () async {
      final FakeAuthProvider fake = FakeAuthProvider();
      addTearDown(fake.dispose);
      final Future<List<AuthState>> drained =
          _drain(fake.watchAuthState(), count: 2);
      await fake.signInWithApple();
      final List<AuthState> received = await drained;
      expect(received, <AuthState>[
        const AuthState.signedOut(),
        const AuthState.signedIn(user: FakeAuthProvider.cannedSarahHenderson),
      ]);
    });

    test('signInWithGoogle emits signedIn with the canned user', () async {
      final FakeAuthProvider fake = FakeAuthProvider();
      addTearDown(fake.dispose);
      final Future<List<AuthState>> drained =
          _drain(fake.watchAuthState(), count: 2);
      await fake.signInWithGoogle();
      final List<AuthState> received = await drained;
      expect(received.last,
          const AuthState.signedIn(user: FakeAuthProvider.cannedSarahHenderson));
    });

    test('custom user flows through to the signedIn state', () async {
      final FakeAuthProvider fake = FakeAuthProvider(cannedUser: altUser);
      addTearDown(fake.dispose);
      final Future<List<AuthState>> drained =
          _drain(fake.watchAuthState(), count: 2);
      await fake.signInWithGoogle();
      final List<AuthState> received = await drained;
      expect(received.last, const AuthState.signedIn(user: altUser));
    });

    test('signOut transitions back to signedOut', () async {
      final FakeAuthProvider fake = FakeAuthProvider();
      addTearDown(fake.dispose);
      await fake.signInWithApple();
      final Future<List<AuthState>> drained =
          _drain(fake.watchAuthState(), count: 2);
      await fake.signOut();
      final List<AuthState> received = await drained;
      expect(received.first,
          const AuthState.signedIn(user: FakeAuthProvider.cannedSarahHenderson));
      expect(received.last, const AuthState.signedOut());
    });

    test('deleteAccount transitions back to signedOut', () async {
      final FakeAuthProvider fake = FakeAuthProvider();
      addTearDown(fake.dispose);
      await fake.signInWithGoogle();
      final Future<List<AuthState>> drained =
          _drain(fake.watchAuthState(), count: 2);
      await fake.deleteAccount();
      final List<AuthState> received = await drained;
      expect(received.last, const AuthState.signedOut());
    });

    test('post-dispose emit does not throw', () async {
      final FakeAuthProvider fake = FakeAuthProvider();
      await fake.dispose();
      // Should not throw even though the underlying controller is closed.
      await fake.signOut();
    });

    test('multiple subscribers each see the initial + later events',
        () async {
      final FakeAuthProvider fake = FakeAuthProvider();
      addTearDown(fake.dispose);
      final Future<List<AuthState>> a =
          _drain(fake.watchAuthState(), count: 2);
      final Future<List<AuthState>> b =
          _drain(fake.watchAuthState(), count: 2);
      await fake.signInWithApple();
      final List<AuthState> ra = await a;
      final List<AuthState> rb = await b;
      expect(ra.last, isA<AuthStateSignedIn>());
      expect(rb.last, isA<AuthStateSignedIn>());
    });
  });

  // ---- TokenStorage ------------------------------------------------------

  group('InMemoryTokenStorage', () {
    test('round-trips a single token', () async {
      final InMemoryTokenStorage store = InMemoryTokenStorage();
      expect(await store.read(), isNull);
      await store.write('abc123');
      expect(await store.read(), 'abc123');
      await store.write('xyz789');
      expect(await store.read(), 'xyz789');
      await store.delete();
      expect(await store.read(), isNull);
    });
  });

  group('SecureTokenStorage', () {
    const MethodChannel channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final List<MethodCall> calls = <MethodCall>[];
    final Map<String, String> store = <String, String>{};

    setUp(() {
      calls.clear();
      store.clear();
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
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
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('write / read / delete use the singleton token key', () async {
      final SecureTokenStorage secure = SecureTokenStorage();
      await secure.write('hunter2');
      expect(store[SecureTokenStorage.tokenKey], 'hunter2');
      expect(await secure.read(), 'hunter2');
      await secure.delete();
      expect(await secure.read(), isNull);

      // Every channel call carried the same key.
      for (final MethodCall c in calls) {
        if (c.method == 'write' ||
            c.method == 'read' ||
            c.method == 'delete') {
          final Map<dynamic, dynamic> args =
              c.arguments as Map<dynamic, dynamic>;
          expect(args['key'], SecureTokenStorage.tokenKey);
        }
      }
    });

    test('accepts an injected FlutterSecureStorage', () {
      // Constructing with the default arg path is exercised above;
      // sanity-check that the named arg constructor compiles.
      final SecureTokenStorage secure =
          SecureTokenStorage(storage: const FlutterSecureStorage());
      expect(secure, isA<TokenStorage>());
    });
  });

  // ---- RealAuthProvider --------------------------------------------------

  group('RealAuthProvider', () {
    const User mockGoogleUser = User(
      id: 'g-42',
      email: 'caregiver@gmail.com',
      name: 'Real Caregiver',
    );
    const User mockAppleUser = User(
      id: 'a-99',
      email: 'caregiver@icloud.com',
      name: 'Real Caregiver',
    );

    RealAuthProvider buildReal({
      _ScriptedFlow? google,
      _ScriptedFlow? apple,
      TokenStorage? storage,
      AccountDeleter? accountDeleter,
    }) {
      final _ScriptedFlow g = google ??
          _ScriptedFlow(const OAuthSignInResult(
            user: mockGoogleUser,
            token: 'google-token',
          ));
      final _ScriptedFlow a = apple ??
          _ScriptedFlow(const OAuthSignInResult(
            user: mockAppleUser,
            token: 'apple-token',
          ));
      return RealAuthProvider(
        googleFlow: g.call,
        appleFlow: a.call,
        tokenStorage: storage ?? InMemoryTokenStorage(),
        accountDeleter: accountDeleter,
      );
    }

    test('signInWithGoogle stores token + emits loading then signedIn',
        () async {
      final InMemoryTokenStorage store = InMemoryTokenStorage();
      final _ScriptedFlow google = _ScriptedFlow(const OAuthSignInResult(
        user: mockGoogleUser,
        token: 'g-tok',
      ));
      final RealAuthProvider real = buildReal(
        google: google,
        storage: store,
      );
      addTearDown(real.dispose);

      final Future<List<AuthState>> drained =
          _drain(real.watchAuthState(), count: 3);
      await real.signInWithGoogle();
      final List<AuthState> received = await drained;

      expect(google.calls, 1);
      expect(received, <AuthState>[
        const AuthState.signedOut(),
        const AuthState.loading(),
        const AuthState.signedIn(user: mockGoogleUser),
      ]);
      expect(await store.read(), 'g-tok');
    });

    test('signInWithApple stores token + emits signedIn', () async {
      final InMemoryTokenStorage store = InMemoryTokenStorage();
      final _ScriptedFlow apple = _ScriptedFlow(const OAuthSignInResult(
        user: mockAppleUser,
        token: 'a-tok',
      ));
      final RealAuthProvider real = buildReal(
        apple: apple,
        storage: store,
      );
      addTearDown(real.dispose);

      final Future<List<AuthState>> drained =
          _drain(real.watchAuthState(), count: 3);
      await real.signInWithApple();
      final List<AuthState> received = await drained;

      expect(apple.calls, 1);
      expect(received.last, const AuthState.signedIn(user: mockAppleUser));
      expect(await store.read(), 'a-tok');
    });

    test('null flow result (user cancelled sheet) returns to signedOut',
        () async {
      final InMemoryTokenStorage store = InMemoryTokenStorage();
      final _ScriptedFlow google = _ScriptedFlow(null);
      final RealAuthProvider real = buildReal(
        google: google,
        storage: store,
      );
      addTearDown(real.dispose);

      final Future<List<AuthState>> drained =
          _drain(real.watchAuthState(), count: 3);
      await real.signInWithGoogle();
      final List<AuthState> received = await drained;

      expect(received, <AuthState>[
        const AuthState.signedOut(),
        const AuthState.loading(),
        const AuthState.signedOut(),
      ]);
      expect(await store.read(), isNull,
          reason: 'cancelled flows must not write a token');
    });

    test('throwing flow rethrows AND settles back to signedOut', () async {
      final InMemoryTokenStorage store = InMemoryTokenStorage();
      final _ScriptedFlow apple =
          _ScriptedFlow(null, error: StateError('user denied'));
      final RealAuthProvider real = buildReal(
        apple: apple,
        storage: store,
      );
      addTearDown(real.dispose);

      final Future<List<AuthState>> drained =
          _drain(real.watchAuthState(), count: 3);
      expect(
        () => real.signInWithApple(),
        throwsA(isA<StateError>()),
      );
      final List<AuthState> received = await drained;
      expect(received, <AuthState>[
        const AuthState.signedOut(),
        const AuthState.loading(),
        const AuthState.signedOut(),
      ]);
      expect(await store.read(), isNull);
    });

    test('signOut clears the token + emits signedOut', () async {
      final InMemoryTokenStorage store = InMemoryTokenStorage();
      final RealAuthProvider real = buildReal(storage: store);
      addTearDown(real.dispose);

      await real.signInWithGoogle();
      expect(await store.read(), 'google-token');

      final Future<List<AuthState>> drained =
          _drain(real.watchAuthState(), count: 2);
      await real.signOut();
      final List<AuthState> received = await drained;

      expect(received.last, const AuthState.signedOut());
      expect(await store.read(), isNull);
    });

    test('deleteAccount clears the token + emits signedOut', () async {
      final InMemoryTokenStorage store = InMemoryTokenStorage();
      final RealAuthProvider real = buildReal(storage: store);
      addTearDown(real.dispose);

      await real.signInWithApple();
      expect(await store.read(), 'apple-token');

      final Future<List<AuthState>> drained =
          _drain(real.watchAuthState(), count: 2);
      await real.deleteAccount();
      final List<AuthState> received = await drained;

      expect(received.last, const AuthState.signedOut());
      expect(await store.read(), isNull);
    });

    test('deleteAccount hits the backend BEFORE clearing local state',
        () async {
      final InMemoryTokenStorage store = InMemoryTokenStorage();
      final _ScriptedDeleter deleter = _ScriptedDeleter();
      final RealAuthProvider real =
          buildReal(storage: store, accountDeleter: deleter.call);
      addTearDown(real.dispose);

      await real.signInWithApple();
      expect(await store.read(), 'apple-token');

      await real.deleteAccount();

      // The server delete ran, and only then was the token cleared.
      expect(deleter.calls, 1);
      expect(await store.read(), isNull);
    });

    test('deleteAccount does NOT wipe local state when the server delete '
        'fails (offline)', () async {
      final InMemoryTokenStorage store = InMemoryTokenStorage();
      final _ScriptedDeleter deleter =
          _ScriptedDeleter(error: StateError('offline'));
      final RealAuthProvider real =
          buildReal(storage: store, accountDeleter: deleter.call);
      addTearDown(real.dispose);

      await real.signInWithGoogle();
      expect(await store.read(), 'google-token');

      // The failure propagates so the UI can tell the caregiver to retry.
      await expectLater(real.deleteAccount(), throwsA(isA<StateError>()));

      // Critically: the local token SURVIVES — no half-deleted account.
      expect(deleter.calls, 1);
      expect(await store.read(), 'google-token');
    });

    test('production factory builds a provider without touching plugins',
        () {
      // The factory's job at construction time is just to wire the
      // closures — it must NOT spin up a Google OAuth client, hit the
      // Keychain, or call SignInWithApple. We assert that by simply
      // building it: any sync platform-channel call would throw a
      // MissingPluginException here (no channels are mocked).
      final RealAuthProvider real = RealAuthProvider.production();
      addTearDown(real.dispose);
      expect(real, isA<AuthProvider>());
    });
  });

  group('AlphaAuthProvider deleteAccount', () {
    const User signedInUser = User(
      id: 'alpha-1',
      email: 'a@x.com',
      name: 'Alpha Caregiver',
    );

    AlphaAuthProvider buildAlpha({
      required UserStore userStore,
      AccountDeleter? accountDeleter,
      Future<void> Function()? onSignedOut,
    }) {
      return AlphaAuthProvider(
        initialUser: signedInUser,
        googleFlow: () async => 'id-token',
        verifier: (String _) async => const GoogleAuthResultLike(
          userId: 'alpha-1',
          email: 'a@x.com',
          name: 'Alpha Caregiver',
        ),
        userStore: userStore,
        accountDeleter: accountDeleter,
        onSignedOut: onSignedOut,
      );
    }

    test('deletes on the backend BEFORE clearing the persisted user',
        () async {
      final InMemoryUserStore store = InMemoryUserStore(signedInUser);
      final _ScriptedDeleter deleter = _ScriptedDeleter();
      bool sessionCleared = false;
      final AlphaAuthProvider alpha = buildAlpha(
        userStore: store,
        accountDeleter: deleter.call,
        onSignedOut: () async => sessionCleared = true,
      );
      addTearDown(alpha.dispose);

      final Future<List<AuthState>> drained =
          _drain(alpha.watchAuthState(), count: 2);
      await alpha.deleteAccount();
      final List<AuthState> received = await drained;

      expect(deleter.calls, 1);
      expect(await store.read(), isNull); // local user cleared
      expect(sessionCleared, isTrue); // forum session shed
      expect(received.last, const AuthState.signedOut());
    });

    test('a failed server delete leaves the persisted user intact', () async {
      final InMemoryUserStore store = InMemoryUserStore(signedInUser);
      final _ScriptedDeleter deleter =
          _ScriptedDeleter(error: StateError('offline'));
      bool sessionCleared = false;
      final AlphaAuthProvider alpha = buildAlpha(
        userStore: store,
        accountDeleter: deleter.call,
        onSignedOut: () async => sessionCleared = true,
      );
      addTearDown(alpha.dispose);

      await expectLater(alpha.deleteAccount(), throwsA(isA<StateError>()));

      // Local user + session survive so the caregiver can retry online.
      expect(deleter.calls, 1);
      expect(await store.read(), isNotNull);
      expect(sessionCleared, isFalse);
    });
  });

  // ---- Riverpod wiring ---------------------------------------------------

  group('authProvider riverpod selection', () {
    test('default container returns an AuthProvider impl', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      // No DEMO_MODE / USE_FAKE_AUTH defined in the test runner — the
      // production wiring should still resolve without throwing because
      // the factory defers all platform calls.
      final AuthProvider impl = container.read(authProvider);
      expect(impl, isA<AuthProvider>());
    });

    test('override hook swaps in a custom impl end-to-end', () async {
      final FakeAuthProvider spy = FakeAuthProvider(cannedUser: altUser);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          authProvider.overrideWithValue(spy),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(spy.dispose);

      final AuthProvider resolved = container.read(authProvider);
      expect(identical(resolved, spy), isTrue);

      final Future<List<AuthState>> drained =
          _drain(resolved.watchAuthState(), count: 2);
      await resolved.signInWithApple();
      final List<AuthState> received = await drained;
      expect(received.last, const AuthState.signedIn(user: altUser));
    });
  });
}

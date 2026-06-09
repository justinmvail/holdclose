import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/services/forum_api_client.dart' show GoogleAuthException;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The alpha-tester auth provider ([AlphaAuthProvider]): Google-ONLY (user
/// decision). REAL Google sign-in verified by the backend (the account
/// spine), persisted via [UserStore] so a returning Google tester is
/// restored to Home across launches. There is NO local "just start" bypass,
/// and a stale local identity is never auto-resumed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// A Google flow that hands back [idToken] (or null to model a cancelled
  /// chooser / throws [error]). Records its call count.
  GoogleIdTokenFlow scriptedGoogleFlow(String? idToken, {Object? error}) {
    return () async {
      if (error != null) throw error;
      return idToken;
    };
  }

  /// A backend verifier that returns [result] (or throws [error]) without
  /// any network — the unit-test seam for `/auth/google`.
  GoogleIdTokenVerifier scriptedVerifier(
    GoogleAuthResultLike? result, {
    Object? error,
  }) {
    return (String idToken) async {
      if (error != null) throw error;
      return result!;
    };
  }

  AlphaAuthProvider buildAlpha({
    GoogleIdTokenFlow? googleFlow,
    GoogleIdTokenVerifier? verifier,
    User? initialUser,
    UserStore? userStore,
  }) {
    return AlphaAuthProvider(
      googleFlow: googleFlow ?? scriptedGoogleFlow('id-token'),
      verifier: verifier ??
          scriptedVerifier(const GoogleAuthResultLike(
            userId: 'google-uid-1',
            email: 'caregiver@gmail.com',
            name: 'Real Caregiver',
          )),
      initialUser: initialUser,
      userStore: userStore,
    );
  }

  test('starts signedOut with no persisted user and no preload', () async {
    final AlphaAuthProvider auth = buildAlpha();
    addTearDown(auth.dispose);
    expect(await auth.watchAuthState().first, isA<AuthStateSignedOut>());
  });

  test('starts signedIn when seeded with a preloaded user (no flash)',
      () async {
    const User user = User(id: 'backend-1', email: 'a@b.co', name: 'Judd');
    final AlphaAuthProvider auth = buildAlpha(initialUser: user);
    addTearDown(auth.dispose);

    final AuthState state = await auth.watchAuthState().first;
    expect(state, isA<AuthStateSignedIn>());
    expect((state as AuthStateSignedIn).user.name, 'Judd');
  });

  // ---- No local auto-resume ---------------------------------------------

  test(
      'a stale local-only identity is NOT auto-resumed — no persisted Google '
      'user means readPersistedAlphaUser is null and the provider stays '
      'signedOut', () async {
    // Simulate a tester who previously used the (removed) local bypass:
    // the old tester-name + install-id keys may linger in prefs, but there
    // is NO persisted auth User. The launch restore must return null.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'feedback.tester_name': 'Old Local Judd',
      'careblazers.tester.install_id': 'tester-stale-123',
    });

    expect(await readPersistedAlphaUser(), isNull);

    final AlphaAuthProvider auth = buildAlpha(
      initialUser: await readPersistedAlphaUser(),
    );
    addTearDown(auth.dispose);
    expect(await auth.watchAuthState().first, isA<AuthStateSignedOut>());
  });

  // ---- Persisted Google session restore ---------------------------------

  test('signInWithGoogle persists the verified user for next-launch restore',
      () async {
    const UserStore store = UserStore();
    final AlphaAuthProvider auth = buildAlpha(
      googleFlow: scriptedGoogleFlow('the-id-token'),
      verifier: scriptedVerifier(const GoogleAuthResultLike(
        userId: 'backend-spine-id',
        email: 'real@gmail.com',
        name: 'Verified Caregiver',
      )),
      userStore: store,
    );
    addTearDown(auth.dispose);

    await auth.signInWithGoogle();

    // The verified user is now persisted, so a fresh launch restores it.
    final User? restored = await readPersistedAlphaUser();
    expect(restored, isNotNull);
    expect(restored!.id, 'backend-spine-id');
    expect(restored.email, 'real@gmail.com');
    expect(restored.name, 'Verified Caregiver');
  });

  test('a returning Google tester is restored to signedIn from the persisted '
      'user', () async {
    // First session: sign in, which persists the user.
    final AlphaAuthProvider first = buildAlpha();
    addTearDown(first.dispose);
    await first.signInWithGoogle();

    // Next launch: main() seeds initialUser from readPersistedAlphaUser().
    final User? restored = await readPersistedAlphaUser();
    final AlphaAuthProvider second = buildAlpha(initialUser: restored);
    addTearDown(second.dispose);

    final AuthState state = await second.watchAuthState().first;
    expect(state, isA<AuthStateSignedIn>());
    expect((state as AuthStateSignedIn).user.name, 'Real Caregiver');
  });

  // ---- Real Google path -------------------------------------------------

  test('signInWithGoogle signs in as the backend-verified spine', () async {
    final AlphaAuthProvider auth = buildAlpha(
      googleFlow: scriptedGoogleFlow('the-id-token'),
      verifier: scriptedVerifier(const GoogleAuthResultLike(
        userId: 'backend-spine-id',
        email: 'real@gmail.com',
        name: 'Verified Caregiver',
      )),
    );
    addTearDown(auth.dispose);

    await auth.signInWithGoogle();

    final AuthState state = await auth.watchAuthState().first;
    expect(state, isA<AuthStateSignedIn>());
    final User user = (state as AuthStateSignedIn).user;
    // The forum JWT `sub` spine is the BACKEND id, not Google's raw id.
    expect(user.id, 'backend-spine-id');
    expect(user.email, 'real@gmail.com');
    expect(user.name, 'Verified Caregiver');
  });

  test('signInWithGoogle cancellation (null id token) is benign signedOut',
      () async {
    final AlphaAuthProvider auth = buildAlpha(
      googleFlow: scriptedGoogleFlow(null),
    );
    addTearDown(auth.dispose);

    await auth.signInWithGoogle(); // no throw
    expect(await auth.watchAuthState().first, isA<AuthStateSignedOut>());
    // Cancellation persists nothing.
    expect(await readPersistedAlphaUser(), isNull);
  });

  test('signInWithGoogle surfaces a backend rejection + stays signedOut',
      () async {
    final AlphaAuthProvider auth = buildAlpha(
      googleFlow: scriptedGoogleFlow('bad-token'),
      verifier: scriptedVerifier(
        null,
        error: const GoogleAuthException(
          statusCode: 401,
          code: 'invalid_token',
        ),
      ),
    );
    addTearDown(auth.dispose);

    await expectLater(
      auth.signInWithGoogle(),
      throwsA(isA<GoogleAuthException>()),
    );
    expect(await auth.watchAuthState().first, isA<AuthStateSignedOut>());
  });

  test('signInWithGoogle rethrows a sheet error + stays signedOut', () async {
    final AlphaAuthProvider auth = buildAlpha(
      googleFlow: scriptedGoogleFlow(null, error: StateError('sheet failed')),
    );
    addTearDown(auth.dispose);

    await expectLater(
      auth.signInWithGoogle(),
      throwsA(isA<StateError>()),
    );
    expect(await auth.watchAuthState().first, isA<AuthStateSignedOut>());
  });

  // ---- Sign out ---------------------------------------------------------

  test('signOut clears the persisted user and returns to signedOut',
      () async {
    final AlphaAuthProvider auth = buildAlpha();
    addTearDown(auth.dispose);
    await auth.signInWithGoogle();
    expect(await readPersistedAlphaUser(), isNotNull);

    await auth.signOut();

    expect(await auth.watchAuthState().first, isA<AuthStateSignedOut>());
    expect(await readPersistedAlphaUser(), isNull);
  });

  test('signInWithApple is a benign no-op (Apple not wired in alpha)',
      () async {
    final AlphaAuthProvider auth = buildAlpha();
    addTearDown(auth.dispose);
    await auth.signInWithApple();
    expect(await auth.watchAuthState().first, isA<AuthStateSignedOut>());
    expect(await readPersistedAlphaUser(), isNull);
  });
}

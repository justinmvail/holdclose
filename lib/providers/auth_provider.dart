import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../services/forum_api_client.dart';

part 'auth_provider.freezed.dart';
part 'auth_provider.g.dart';

/// The signed-in caregiver (BUILD_SPEC.md §6.4).
///
/// Only the three fields the in-app surfaces need: [id] (idempotent
/// across re-installs, sourced from the OAuth provider), [email] (shown
/// in Settings → Account), [name] (shown wherever the app addresses the
/// caregiver by name). The OAuth provider's full profile is intentionally
/// not modelled — v1 has no backend that would consume the rest.
@freezed
abstract class User with _$User {
  const factory User({
    required String id,
    required String email,
    required String name,
  }) = _User;

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
}

/// Auth state machine (BUILD_SPEC.md §6.4).
///
/// [AuthState.signedOut] is the initial state and the post-`signOut`
/// state. [AuthState.signedIn] carries the [User] that the welcome and
/// settings screens render. [AuthState.loading] surfaces a spinner on
/// the sign-in screen while the OAuth round-trip is in flight — the
/// state machine flips back to `signedOut` if the user cancels the
/// system sheet or the call throws.
@freezed
sealed class AuthState with _$AuthState {
  const factory AuthState.signedOut() = AuthStateSignedOut;
  const factory AuthState.signedIn({required User user}) = AuthStateSignedIn;
  const factory AuthState.loading() = AuthStateLoading;
}

/// Backend for OAuth + token persistence (BUILD_SPEC.md §6.4).
///
/// Two v1 implementations: [RealAuthProvider] (wraps `google_sign_in`,
/// `sign_in_with_apple`, and `flutter_secure_storage`) and
/// [FakeAuthProvider] (returns the canned Sarah Henderson user without
/// touching any platform plugin). The app never imports either concrete
/// class directly; it goes through [authProvider] which picks based on
/// the `DEMO_MODE` / `USE_FAKE_AUTH` build defines.
abstract class AuthProvider {
  /// Emits the current [AuthState] on subscribe, then every subsequent
  /// transition. Broadcast — multiple widgets can listen concurrently.
  Stream<AuthState> watchAuthState();

  /// Kick off the Apple OAuth flow. Resolves once the state machine
  /// has settled (either signedIn or back to signedOut if cancelled).
  Future<void> signInWithApple();

  /// Kick off the Google OAuth flow. Same settling contract as
  /// [signInWithApple].
  Future<void> signInWithGoogle();

  /// Clear local token state and transition to [AuthState.signedOut].
  /// Does not call any remote revoke endpoint in v1 (no backend yet).
  Future<void> signOut();

  /// Same outward shape as [signOut] in v1 since there's no server-side
  /// account to delete. Kept as a separate method so the Settings →
  /// Account → "Delete account" button can wire to a different impl
  /// once the backend lands.
  Future<void> deleteAccount();
}

/// Carries the two facts the [AuthProvider] needs out of an OAuth flow:
/// the [User] to expose via [AuthState.signedIn] and the bearer/identity
/// [token] to park in [TokenStorage] for the future API client.
///
/// Returned by [OAuthFlow]; a null return means the user cancelled the
/// sheet (e.g. closed the Google chooser) — the provider treats that as
/// a benign back-to-signedOut transition, not an error.
class OAuthSignInResult {
  const OAuthSignInResult({required this.user, required this.token});
  final User user;
  final String token;
}

/// Function that drives one OAuth round-trip. The production wiring lives
/// in [RealAuthProvider.production]; tests inject deterministic flows
/// that return canned results without spinning up real OAuth UI.
typedef OAuthFlow = Future<OAuthSignInResult?> Function();

/// Drives the Google sign-in sheet and returns the Google **ID token**
/// (a signed JWT whose `aud` is our backend's Web client id). A null
/// return means the caregiver cancelled the chooser — the provider
/// treats that as a benign back-to-signedOut transition. The id token is
/// the only thing the backend needs: it verifies the token's signature +
/// audience and returns the account spine, so the provider never trusts
/// Google's client-side profile fields directly.
typedef GoogleIdTokenFlow = Future<String?> Function();

/// Exchanges a Google ID token for the backend's verified account spine.
/// Production wires this to [ForumApiClient.verifyGoogleIdToken]; tests
/// inject a deterministic fake so the auth path never touches the network
/// or real Google. Throws on backend rejection (the provider rethrows so
/// the sign-in screen can surface the error).
typedef GoogleIdTokenVerifier = Future<GoogleAuthResultLike> Function(
  String idToken,
);

/// The two facts [AlphaAuthProvider] needs out of the backend's
/// `/auth/google` response: the stable [userId] (the forum JWT `sub`
/// spine) and the [email]/[name] the in-app surfaces render. Mirrors
/// `GoogleAuthResult` in `forum_api_client.dart`, restated here so this
/// provider file doesn't depend on the API-client layer (keeps the auth
/// interface importable by tests that don't pull in Dio).
class GoogleAuthResultLike {
  const GoogleAuthResultLike({
    required this.userId,
    required this.email,
    required this.name,
  });

  final String userId;
  final String email;
  final String name;
}

/// Persistent store for the OAuth bearer/identity token
/// (BUILD_SPEC.md §6.4 + §13.2).
///
/// Pulled behind an interface so [RealAuthProvider] is unit-testable
/// without standing up the iOS Keychain / Android Keystore platform
/// channels. Production uses [SecureTokenStorage]; tests use
/// [InMemoryTokenStorage].
abstract class TokenStorage {
  Future<void> write(String token);
  Future<String?> read();
  Future<void> delete();
}

/// `flutter_secure_storage`-backed [TokenStorage] (BUILD_SPEC.md §13.2).
class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Single key — v1 only ever holds one token at a time.
  static const String tokenKey = 'careblazers.auth.token';

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String token) =>
      _storage.write(key: tokenKey, value: token);

  @override
  Future<String?> read() => _storage.read(key: tokenKey);

  @override
  Future<void> delete() => _storage.delete(key: tokenKey);
}

/// In-memory [TokenStorage] for tests + the demo tour. Holds whatever was
/// most recently written until [delete] clears it.
class InMemoryTokenStorage implements TokenStorage {
  String? _token;

  @override
  Future<void> write(String token) async {
    _token = token;
  }

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> delete() async {
    _token = null;
  }
}

/// Persistent store for the signed-in [User] so a returning Google tester
/// is restored straight to Home across launches (no re-tap). The bearer
/// token already persists via [TokenStorage]; this parks the user spine
/// (id/email/name) alongside it. Backed by `shared_preferences` (the user
/// fields are non-secret display data — the secret token stays in the
/// keychain via [SecureTokenStorage]).
///
/// Cleared by `signOut`/`deleteAccount`. Restored at launch by
/// [readPersistedAlphaUser], which seeds [AlphaAuthProvider]'s initial
/// state.
class UserStore {
  const UserStore();

  static const String userKey = 'careblazers.auth.user';

  /// The persisted user, or null if none is saved (signed out / first run).
  Future<User?> read() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(userKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return User.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      // A malformed value must never brick startup — treat it as absent.
      return null;
    }
  }

  Future<void> write(User user) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(userKey, jsonEncode(user.toJson()));
  }

  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(userKey);
  }
}

/// Real, OAuth-backed [AuthProvider] (BUILD_SPEC.md §6.4).
///
/// The two [OAuthFlow] closures isolate the platform plugin calls from
/// the state-machine logic so the provider is fully unit-testable. The
/// [RealAuthProvider.production] factory wires real
/// `google_sign_in.signIn()` and `SignInWithApple.getAppleIDCredential`
/// calls; tests pass in deterministic flow functions.
class RealAuthProvider implements AuthProvider {
  RealAuthProvider({
    required OAuthFlow googleFlow,
    required OAuthFlow appleFlow,
    TokenStorage? tokenStorage,
  })  : _googleFlow = googleFlow,
        _appleFlow = appleFlow,
        _tokenStorage = tokenStorage ?? SecureTokenStorage();

  /// Wire the production OAuth closures. Constructing the `GoogleSignIn`
  /// client is cheap — it doesn't touch the platform channel until
  /// `signIn()` runs — so this factory is safe to call at riverpod
  /// provider init time.
  factory RealAuthProvider.production() {
    final GoogleSignIn google = buildProductionGoogleSignIn();
    return RealAuthProvider(
      tokenStorage: SecureTokenStorage(),
      googleFlow: () async {
        final GoogleSignInAccount? account = await google.signIn();
        if (account == null) return null;
        final GoogleSignInAuthentication auth = await account.authentication;
        return OAuthSignInResult(
          user: User(
            id: account.id,
            email: account.email,
            name: account.displayName ?? account.email,
          ),
          // Prefer the id token for backend exchange; fall back to the
          // access token if the OAuth client didn't request id tokens
          // (which the v1 client does, but a future config change might
          // not).
          token: auth.idToken ?? auth.accessToken ?? '',
        );
      },
      appleFlow: () async {
        final AuthorizationCredentialAppleID credential =
            await SignInWithApple.getAppleIDCredential(
          scopes: const <AppleIDAuthorizationScopes>[
            AppleIDAuthorizationScopes.email,
            AppleIDAuthorizationScopes.fullName,
          ],
        );
        final String displayName = <String>[
          credential.givenName ?? '',
          credential.familyName ?? '',
        ].where((String s) => s.isNotEmpty).join(' ');
        return OAuthSignInResult(
          user: User(
            // userIdentifier is non-null on iOS/macOS (the only platforms
            // the v1 Apple flow runs on); the fallback covers a stubbed
            // Android implementation.
            id: credential.userIdentifier ?? 'apple-user',
            email: credential.email ?? '',
            name: displayName.isEmpty ? 'Careblazer' : displayName,
          ),
          // identityToken is the JWT we'd hand to a backend; on
          // re-authorization Apple omits it, so fall back to the
          // authorizationCode (which is always present).
          token: credential.identityToken ?? credential.authorizationCode,
        );
      },
    );
  }

  final OAuthFlow _googleFlow;
  final OAuthFlow _appleFlow;
  final TokenStorage _tokenStorage;

  AuthState _state = const AuthState.signedOut();
  final StreamController<AuthState> _changes =
      StreamController<AuthState>.broadcast();

  /// Release the broadcast controller. Wired to `ref.onDispose` by the
  /// riverpod provider.
  Future<void> dispose() => _changes.close();

  @override
  Stream<AuthState> watchAuthState() =>
      _replayBroadcast(_changes, () => _state);

  @override
  Future<void> signInWithApple() => _runFlow(_appleFlow);

  @override
  Future<void> signInWithGoogle() => _runFlow(_googleFlow);

  Future<void> _runFlow(OAuthFlow flow) async {
    _emit(const AuthState.loading());
    final OAuthSignInResult? result;
    try {
      result = await flow();
    } catch (_) {
      // The OAuth UI throwing (network, user cancel via exception on
      // some platforms) settles us back to signedOut; rethrow so the
      // sign-in screen can surface the error.
      _emit(const AuthState.signedOut());
      rethrow;
    }
    if (result == null) {
      // Explicit cancel — the user closed the sheet. No error, just
      // back to signedOut.
      _emit(const AuthState.signedOut());
      return;
    }
    await _tokenStorage.write(result.token);
    _emit(AuthState.signedIn(user: result.user));
  }

  @override
  Future<void> signOut() async {
    await _tokenStorage.delete();
    _emit(const AuthState.signedOut());
  }

  @override
  Future<void> deleteAccount() async {
    await _tokenStorage.delete();
    _emit(const AuthState.signedOut());
  }

  void _emit(AuthState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }
}

/// Fake [AuthProvider] for the demo tour + widget tests
/// (BUILD_SPEC.md §6.4 + §5.12 demo-skip).
///
/// Both [signInWithApple] and [signInWithGoogle] resolve to a
/// signedIn state carrying [cannedSarahHenderson] — the same canned
/// caregiver the demo tour walks through. Tests can override [user] to
/// pin a different identity.
class FakeAuthProvider implements AuthProvider {
  FakeAuthProvider({User? cannedUser})
      : user = cannedUser ?? cannedSarahHenderson;

  /// Canned demo user (BUILD_SPEC.md §6.4 — Sarah Henderson is Mary
  /// Henderson's primary caregiver in the seed data, §9.1).
  static const User cannedSarahHenderson = User(
    id: 'demo-user-sarah',
    email: 'demo@careblazers.app',
    name: 'Sarah Henderson',
  );

  final User user;
  AuthState _state = const AuthState.signedOut();
  final StreamController<AuthState> _changes =
      StreamController<AuthState>.broadcast();

  /// Release the broadcast controller. Wired to `ref.onDispose` by the
  /// riverpod provider.
  Future<void> dispose() => _changes.close();

  @override
  Stream<AuthState> watchAuthState() =>
      _replayBroadcast(_changes, () => _state);

  @override
  Future<void> signInWithApple() async => _signIn();

  @override
  Future<void> signInWithGoogle() async => _signIn();

  @override
  Future<void> signOut() async => _emit(const AuthState.signedOut());

  @override
  Future<void> deleteAccount() async => _emit(const AuthState.signedOut());

  void _signIn() {
    _emit(AuthState.signedIn(user: user));
  }

  void _emit(AuthState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }
}

/// Alpha-tester [AuthProvider]. Supports BOTH paths:
///
///  * [signInWithGoogle] — REAL Google sign-in. Runs the google_sign_in
///    sheet to get a Google ID token, POSTs it to the backend's
///    `/auth/google` (via the injected [GoogleIdTokenVerifier]), and
///    signs in as the backend's VERIFIED account spine. The backend
///    `user_id` becomes the forum JWT `sub`, so the identity is real and
///    survives reinstall.
///
/// The alpha build is **Google-only** (user decision): there is no local
/// "just start" bypass. A verified Google [User] is persisted via
/// [UserStore] so a returning tester is restored to signedIn at launch
/// (seeded through [initialUser]) without re-tapping. `signOut` /
/// `deleteAccount` clear that persisted user.
///
/// Apple is not wired in the alpha build (deferred); [signInWithApple] is
/// a benign no-op (the sign-in screen never shows an Apple button in alpha
/// mode) so the interface stays usable.
class AlphaAuthProvider implements AuthProvider {
  AlphaAuthProvider({
    required GoogleIdTokenFlow googleFlow,
    required GoogleIdTokenVerifier verifier,
    User? initialUser,
    UserStore? userStore,
  })  : _googleFlow = googleFlow,
        _verifier = verifier,
        _userStore = userStore ?? const UserStore(),
        _state = initialUser == null
            ? const AuthState.signedOut()
            : AuthState.signedIn(user: initialUser);

  final GoogleIdTokenFlow _googleFlow;
  final GoogleIdTokenVerifier _verifier;
  final UserStore _userStore;
  AuthState _state;
  final StreamController<AuthState> _changes =
      StreamController<AuthState>.broadcast();

  /// Release the broadcast controller. Wired to `ref.onDispose`.
  Future<void> dispose() => _changes.close();

  @override
  Stream<AuthState> watchAuthState() =>
      _replayBroadcast(_changes, () => _state);

  /// Apple isn't wired in alpha — benign no-op (the alpha sign-in screen
  /// never renders an Apple button) so the interface stays uniform.
  @override
  Future<void> signInWithApple() async {
    _emit(const AuthState.signedOut());
  }

  /// REAL Google: run the sheet → get the ID token → verify it with the
  /// backend → persist + sign in as the verified spine. A null id token
  /// means the caregiver cancelled the chooser (benign back-to-signedOut).
  /// A backend rejection rethrows so the sign-in screen surfaces the error.
  @override
  Future<void> signInWithGoogle() async {
    _emit(const AuthState.loading());
    final String? idToken;
    try {
      idToken = await _googleFlow();
    } catch (_) {
      _emit(const AuthState.signedOut());
      rethrow;
    }
    if (idToken == null || idToken.isEmpty) {
      // Cancelled the chooser — no error.
      _emit(const AuthState.signedOut());
      return;
    }
    final GoogleAuthResultLike verified;
    try {
      verified = await _verifier(idToken);
    } catch (_) {
      _emit(const AuthState.signedOut());
      rethrow;
    }
    final User user = User(
      id: verified.userId,
      email: verified.email,
      name: verified.name,
    );
    // Persist the verified user so the next launch restores signedIn
    // straight to Home (no re-tap) — see [readPersistedAlphaUser].
    await _userStore.write(user);
    _emit(AuthState.signedIn(user: user));
  }

  @override
  Future<void> signOut() async {
    await _userStore.clear();
    _emit(const AuthState.signedOut());
  }

  @override
  Future<void> deleteAccount() => signOut();

  void _emit(AuthState next) {
    _state = next;
    if (!_changes.isClosed) _changes.add(next);
  }
}

/// Bridge a broadcast [source] + a `currentState` getter into a stream
/// that:
///
/// 1. emits the current state synchronously on subscribe (no missed
///    initial value for late subscribers), and
/// 2. subscribes to [source] inside `onListen` so no event fired between
///    subscribe + first yield is lost (the same trap async* hits with
///    `yield _state; yield* source.stream;`).
///
/// Mirrors the [InMemoryStorageProvider.watchJournalEntries] pattern in
/// `storage_provider.dart`.
Stream<AuthState> _replayBroadcast(
  StreamController<AuthState> source,
  AuthState Function() currentState,
) {
  late StreamController<AuthState> out;
  StreamSubscription<AuthState>? sub;
  out = StreamController<AuthState>.broadcast(
    onListen: () {
      // Replay current state to every new listener so late subscribers
      // (and subscribers re-mounting after a ListView scroll-off →
      // scroll-back cycle) don't see a blank initial frame.
      out.add(currentState());
      // Subscribe to the source on the FIRST listener only; the
      // broadcast controller fans the source's events out to every
      // subsequent listener without re-subscribing.
      sub ??= source.stream.listen((AuthState s) {
        if (!out.isClosed) out.add(s);
      });
    },
    onCancel: () async {
      // Broadcast onCancel fires only when the LAST listener cancels;
      // tear down the source subscription so it can be re-established
      // on the next listener (avoids leaking the source.stream sub
      // when every consumer has gone away).
      await sub?.cancel();
      sub = null;
    },
  );
  return out.stream;
}

// ---------------------------------------------------------------------------
// Riverpod wiring
// ---------------------------------------------------------------------------

/// Build-time flag (BUILD_SPEC.md §6.4 — `DEMO_MODE`). When true, the
/// app launches into the demo tour and the [authProvider] selector
/// picks the fake.
const bool _demoMode = bool.fromEnvironment(
  'DEMO_MODE',
  defaultValue: false,
);

/// Build-time flag (BUILD_SPEC.md §6.4 — `USE_FAKE_AUTH`). Independent
/// of [_demoMode] so widget-test harnesses can pick the fake without
/// flipping the rest of the demo-mode behavior.
const bool _useFakeAuth = bool.fromEnvironment(
  'USE_FAKE_AUTH',
  defaultValue: false,
);

const bool _useFake = _demoMode || _useFakeAuth;

/// Build-time flag (`ALPHA_FEEDBACK`). When set, the app runs in
/// alpha-tester mode: an [AlphaAuthProvider] (REAL Google verified by the
/// backend, plus a local "just start" name + per-install id fallback)
/// replaces the canned [FakeAuthProvider], so every tester is a distinct,
/// persisted, attributable account. Demo-tour and widget-test builds (no
/// ALPHA_FEEDBACK) keep [FakeAuthProvider].
// ignore: do_not_use_environment
const bool _alphaTesterMode =
    bool.fromEnvironment('ALPHA_FEEDBACK', defaultValue: false);

/// The Web OAuth client id (`--dart-define=GOOGLE_SERVER_CLIENT_ID=...`).
/// Passed to `GoogleSignIn.serverClientId` so the issued ID token's `aud`
/// equals the backend's Web client id on BOTH iOS and Android — that's
/// the audience the backend's `/auth/google` verifier checks. No secret
/// in source: the operator pipes it in at build time.
const String googleServerClientId =
    String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

/// The iOS OAuth client id (`--dart-define=GOOGLE_IOS_CLIENT_ID=...`).
/// Passed to `GoogleSignIn.clientId`; only meaningful on iOS (google_sign_in
/// ignores it on Android). Pairs with the reversed-client-id URL scheme in
/// `ios/Runner/Info.plist`.
const String googleIosClientId =
    String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

/// True when the Google button should be shown/enabled — i.e. the build
/// baked in a Web client id. When false the sign-in screen hides the
/// Google button and the app falls back to the local "just start" path,
/// so an un-configured build still works. A compile-time `const` (the
/// define defaults to the empty string) so it can default a `const`
/// widget constructor.
const bool googleSignInConfigured = googleServerClientId != '';

/// Build the production [GoogleSignIn] client with the build-time client
/// ids wired so the issued ID token's `aud` matches the backend on both
/// platforms. `serverClientId` (Web client id) drives the `aud`; `clientId`
/// (iOS client id) is required by the iOS plugin and ignored elsewhere.
/// Empty defines are passed as null so an un-configured build still
/// constructs a (non-functional) client without throwing.
GoogleSignIn buildProductionGoogleSignIn() => GoogleSignIn(
      scopes: const <String>['email', 'profile'],
      serverClientId:
          googleServerClientId.trim().isEmpty ? null : googleServerClientId,
      clientId: googleIosClientId.trim().isEmpty ? null : googleIosClientId,
    );

/// Drive the production Google sign-in sheet and return the **ID token**
/// (not the access token) — that's the signed JWT the backend's
/// `/auth/google` verifier checks. Null on cancel. Built off
/// [buildProductionGoogleSignIn] so the same client-id config feeds both
/// the [RealAuthProvider] OAuth path and the alpha Google path.
Future<String?> productionGoogleIdTokenFlow() async {
  final GoogleSignIn google = buildProductionGoogleSignIn();
  final GoogleSignInAccount? account = await google.signIn();
  if (account == null) return null;
  final GoogleSignInAuthentication auth = await account.authentication;
  return auth.idToken;
}

/// The persisted Google [User], preloaded from [UserStore] in `main()`
/// before `runApp` so [AlphaAuthProvider] starts signedIn for a returning
/// Google tester — no sign-in-screen flash, no re-tap. Null means no
/// persisted Google session (first launch, or signed out) → starts
/// signedOut → the sign-in screen shows the Google button. Only consulted
/// in alpha-tester builds. A returning tester who only ever used the
/// (now-removed) local bypass has no persisted user here, so they land on
/// sign-in and must use Google.
User? preloadedAlphaUser;

/// Read the persisted Google [User] for alpha-mode launch restore. Called
/// from `main()` before `runApp`; the result seeds [preloadedAlphaUser].
/// Returns null in offline / first-launch / signed-out cases (it only
/// touches local `shared_preferences`, never the network — so a returning
/// Google tester is restored even with no connectivity).
Future<User?> readPersistedAlphaUser() => const UserStore().read();

/// Riverpod-wired backend selection. Widgets and services read
/// `ref.watch(authProvider)` and get whichever impl the build mode
/// picked — they never see the concrete class.
///
/// The function is named `authBackend` (not `auth`) so the class
/// `riverpod_generator` emits is [AuthBackendProvider], avoiding a
/// clash with this file's own abstract [AuthProvider] interface.
/// Consumers read through the [authProvider] alias below.
@Riverpod(keepAlive: true)
AuthProvider authBackend(Ref ref) {
  if (_alphaTesterMode) {
    // Alpha is Google-ONLY (user decision): REAL Google verified by the
    // backend, no local bypass. The verifier reaches the live forum
    // client. [preloadedAlphaUser] restores a returning Google tester to
    // signedIn at launch (persisted via [UserStore]); a stale local
    // identity is NEVER auto-resumed — testers go through Google.
    final AlphaAuthProvider alpha = AlphaAuthProvider(
      initialUser: preloadedAlphaUser,
      googleFlow: productionGoogleIdTokenFlow,
      verifier: (String idToken) async {
        final GoogleAuthResult r =
            await ref.read(forumApiClientProvider).verifyGoogleIdToken(idToken);
        return GoogleAuthResultLike(
          userId: r.userId,
          email: r.email,
          name: r.name,
        );
      },
    );
    ref.onDispose(alpha.dispose);
    return alpha;
  }
  if (_useFake) {
    final FakeAuthProvider fake = FakeAuthProvider();
    ref.onDispose(fake.dispose);
    return fake;
  }
  final RealAuthProvider real = RealAuthProvider.production();
  ref.onDispose(real.dispose);
  return real;
}

/// Natural-language alias for the generated provider. Consumers should
/// always reach for this name — `authBackendProvider` exists only
/// because of the riverpod_generator class-naming collision documented
/// on [authBackend].
final AuthBackendProvider authProvider = authBackendProvider;

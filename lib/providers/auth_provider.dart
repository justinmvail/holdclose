import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

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
    final GoogleSignIn google = GoogleSignIn(
      scopes: const <String>['email', 'profile'],
    );
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
  out = StreamController<AuthState>(
    onListen: () {
      out.add(currentState());
      sub = source.stream.listen((AuthState s) {
        if (!out.isClosed) out.add(s);
      });
    },
    onCancel: () async {
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

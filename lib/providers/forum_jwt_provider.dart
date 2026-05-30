import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'auth_provider.dart';

part 'forum_jwt_provider.g.dart';

/// Build-time injection point for the forum JWT shared secret
/// (BUILD_SPEC.md §13 / Phase 13.9). Operator passes
/// `--dart-define=FORUM_JWT_SECRET=<value>` matching the
/// `wrangler secret put FORUM_JWT_SECRET` set on the deployed Worker.
/// Empty default keeps the binary buildable in environments where the
/// secret isn't piped through (e.g. CI smoke builds); callers that
/// actually mint a token surface a [StateError] rather than signing
/// with the empty string.
const String _compileTimeForumJwtSecret = String.fromEnvironment(
  'FORUM_JWT_SECRET',
);

/// Where [ForumSecretStore] parks the shared secret in
/// `flutter_secure_storage` — Keychain on iOS, Keystore on Android.
/// Single key (v1 only ever holds one secret at a time) namespaced
/// alongside [SecureTokenStorage.tokenKey] so a future "wipe all
/// careblazers secrets" sweep can match a single prefix.
const String forumSecretStorageKey = 'careblazers.forum.jwt_secret';

/// Lazy loader for the forum JWT shared secret (BUILD_SPEC.md §13 +
/// TASKS.md Phase 13.9).
///
/// On first request, reads the build-time `--dart-define=FORUM_JWT_SECRET`
/// value and writes it into `flutter_secure_storage`. Subsequent
/// requests come straight from secure storage so the secret string
/// isn't reloaded from the constant pool on every JWT mint. The
/// indirection also means a future secret-rotation flow can write to
/// secure storage out-of-band (e.g. a `/settings/forum/rotate` admin
/// route) without rebuilding the app.
class ForumSecretStore {
  ForumSecretStore({
    FlutterSecureStorage? storage,
    String compileTimeSecret = _compileTimeForumJwtSecret,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _compileTimeSecret = compileTimeSecret;

  final FlutterSecureStorage _storage;
  final String _compileTimeSecret;

  /// Returns the cached secret, seeding from the compile-time define
  /// on first call. Throws [StateError] if neither secure storage nor
  /// the define carry a value — callers should treat that as "the
  /// caregiver can't reach the forum on this build" and gate forum UI
  /// off rather than crashing the app.
  Future<String> load() async {
    final String? cached = await _storage.read(key: forumSecretStorageKey);
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    if (_compileTimeSecret.isEmpty) {
      throw StateError(
        'FORUM_JWT_SECRET is not set. Rebuild with '
        '`--dart-define=FORUM_JWT_SECRET=<value>` to enable the '
        'caregiver forum.',
      );
    }
    await _storage.write(
      key: forumSecretStorageKey,
      value: _compileTimeSecret,
    );
    return _compileTimeSecret;
  }
}

/// Async getter for the careblazers user id the JWT's `sub` claim
/// resolves to (BUILD_SPEC.md §13 + §6.4). Pulled behind a typedef so
/// [ForumJwtMinter] is unit-testable without standing up the auth
/// state machine — production wiring watches the [authProvider] state.
typedef ForumUserIdLoader = Future<String?> Function();

/// Async loader for the JWT shared secret. Production wires this to
/// [ForumSecretStore.load]; tests inject a constant closure.
typedef ForumSecretLoader = Future<String> Function();

/// Mints — and refreshes — HS256 JWTs for the forum API client
/// (BUILD_SPEC.md §13 + TASKS.md Phase 13.9).
///
/// Tokens carry `{sub: <careblazers_user_id>, iat, exp}` per the
/// Worker's `auth.ts` middleware contract. The minter caches the most
/// recent token until it falls inside the [refreshThreshold] window
/// before expiry — at which point [currentToken] mints a fresh one.
/// A change of signed-in user invalidates the cache immediately so a
/// sign-out-then-sign-in-as-different-user never reuses the previous
/// `sub`.
class ForumJwtMinter {
  ForumJwtMinter({
    required ForumSecretLoader secretLoader,
    required ForumUserIdLoader userIdLoader,
    Duration ttl = const Duration(hours: 1),
    Duration refreshThreshold = const Duration(minutes: 5),
    DateTime Function()? clock,
  })  : _secretLoader = secretLoader,
        _userIdLoader = userIdLoader,
        _ttl = ttl,
        _refreshThreshold = refreshThreshold,
        _clock = clock ?? DateTime.now {
    assert(
      refreshThreshold < ttl,
      'refreshThreshold ($refreshThreshold) must be < ttl ($ttl); '
      'otherwise every call would mint a fresh token.',
    );
  }

  final ForumSecretLoader _secretLoader;
  final ForumUserIdLoader _userIdLoader;
  final Duration _ttl;
  final Duration _refreshThreshold;
  final DateTime Function() _clock;

  String? _cachedToken;
  DateTime? _cachedExpiresAt;
  String? _cachedUserId;

  /// The next time [currentToken] would refresh the cached token,
  /// or null if no token has been minted yet. Exposed for tests +
  /// the Phase 13.10 settings surface that wants to show "session
  /// refreshes in N minutes" diagnostics.
  DateTime? get cachedExpiresAt => _cachedExpiresAt;

  /// Return a non-expired JWT for the current signed-in user. Throws
  /// [StateError] when no user is signed in (the forum UI should gate
  /// on that condition before calling) and rethrows whatever
  /// [_secretLoader] surfaces on a missing build-time secret.
  Future<String> currentToken() async {
    final String? userId = await _userIdLoader();
    if (userId == null || userId.isEmpty) {
      throw StateError(
        'No signed-in careblazers user; cannot mint a forum JWT. '
        'The caller should gate forum surfaces on auth state first.',
      );
    }

    final DateTime now = _clock();
    final bool sameUser = _cachedUserId == userId;
    final bool stillFresh = _cachedToken != null &&
        _cachedExpiresAt != null &&
        _cachedExpiresAt!.isAfter(now.add(_refreshThreshold));
    if (sameUser && stillFresh) {
      return _cachedToken!;
    }

    final String secret = await _secretLoader();
    if (secret.isEmpty) {
      throw StateError(
        'Forum JWT secret loaded empty; refusing to sign with an '
        'empty HMAC key.',
      );
    }
    final DateTime expiresAt = now.add(_ttl);
    final String token = _signHs256(
      secret: secret,
      userId: userId,
      issuedAt: now,
      expiresAt: expiresAt,
    );

    _cachedToken = token;
    _cachedExpiresAt = expiresAt;
    _cachedUserId = userId;
    return token;
  }

  /// Drop the cached token. Call from sign-out so the next forum
  /// request can't accidentally reuse the previous user's `sub`.
  void invalidate() {
    _cachedToken = null;
    _cachedExpiresAt = null;
    _cachedUserId = null;
  }

  /// HS256 sign `{header}.{payload}` per RFC 7519. Built inline rather
  /// than via a JWT library — the Worker only verifies HS256 and we
  /// only ever produce the one claim set, so a third-party dep would
  /// pay no real complexity tax for the dozen-line implementation.
  /// Static + visible so tests can pin the encoding shape against a
  /// known-good vector.
  static String _signHs256({
    required String secret,
    required String userId,
    required DateTime issuedAt,
    required DateTime expiresAt,
  }) {
    final Map<String, Object?> header = <String, Object?>{
      'alg': 'HS256',
      'typ': 'JWT',
    };
    final Map<String, Object?> payload = <String, Object?>{
      'sub': userId,
      'iat': issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      'exp': expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    };
    final String encodedHeader = _base64UrlNoPad(utf8.encode(json.encode(header)));
    final String encodedPayload =
        _base64UrlNoPad(utf8.encode(json.encode(payload)));
    final String signingInput = '$encodedHeader.$encodedPayload';
    final Hmac hmac = Hmac(sha256, utf8.encode(secret));
    final Digest signature = hmac.convert(utf8.encode(signingInput));
    final String encodedSignature = _base64UrlNoPad(signature.bytes);
    return '$signingInput.$encodedSignature';
  }

  /// RFC 7515 §2: JWTs use base64url WITHOUT trailing `=` padding.
  static String _base64UrlNoPad(List<int> bytes) {
    final String encoded = base64Url.encode(bytes);
    int end = encoded.length;
    while (end > 0 && encoded.codeUnitAt(end - 1) == 0x3D) {
      end -= 1;
    }
    return encoded.substring(0, end);
  }
}

// ---------------------------------------------------------------------------
// Riverpod wiring
// ---------------------------------------------------------------------------

/// Production [ForumSecretStore] (BUILD_SPEC.md §13 / Phase 13.9).
/// `keepAlive: true` so the secure-storage read happens once per app
/// session instead of on every forum request.
@Riverpod(keepAlive: true)
ForumSecretStore forumSecretStore(Ref ref) => ForumSecretStore();

/// Production [ForumJwtMinter] (BUILD_SPEC.md §13 / Phase 13.9).
///
/// Wires the secret store + the auth state machine. The user-id loader
/// reads `ref.read(authProvider)` lazily on each `currentToken` call —
/// it can't subscribe with `watch` because the minter is a `keepAlive`
/// singleton and we don't want every auth transition to invalidate
/// every other riverpod consumer. The minter's own invalidation is
/// driven explicitly via [ForumJwtMinter.invalidate] from sign-out
/// handlers (Phase 13.10+ wires that).
@Riverpod(keepAlive: true)
ForumJwtMinter forumJwtMinter(Ref ref) {
  final ForumSecretStore store = ref.watch(forumSecretStoreProvider);
  return ForumJwtMinter(
    secretLoader: store.load,
    userIdLoader: () async {
      final AuthState state = await ref.read(authProvider).watchAuthState().first;
      return switch (state) {
        AuthStateSignedIn(:final User user) => user.id,
        _ => null,
      };
    },
  );
}

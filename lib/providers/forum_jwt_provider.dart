import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/forum_api_client.dart';
import 'auth_provider.dart';

part 'forum_jwt_provider.g.dart';

/// Where the SERVER-minted forum session JWT is persisted —
/// `flutter_secure_storage` (Keychain on iOS, Keystore on Android).
///
/// Security model (2026-06-11 rework): the Worker mints the session
/// token inside `POST /auth/google` after verifying the Google ID
/// token, signed with a secret that exists ONLY on the Worker. The app
/// carries the token opaquely. Nothing in the binary can mint or forge
/// an identity — extracting the app's defines yields no signing key.
const String forumSessionTokenStorageKey = 'careblazers.forum.session_token';

/// Companion key holding the token's expiry as epoch **seconds** (the
/// JWT `exp` claim the Worker reported back as `token_expires_at`).
const String forumSessionExpiryStorageKey =
    'careblazers.forum.session_expires_at';

/// Legacy key from the retired client-side-minting scheme (pre
/// 2026-06-11) that parked the shared HMAC secret on the device. Never
/// written anymore; actively DELETED whenever the session store writes
/// or clears, so updated installs shed the old secret.
const String forumSecretStorageKey = 'careblazers.forum.jwt_secret';

/// A server-minted forum session: the bearer token plus its expiry.
class ForumSession {
  const ForumSession({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;

  bool isExpired(DateTime now) => !expiresAt.isAfter(now);
}

/// Secure-storage persistence for the [ForumSession].
///
/// Pure CRUD — freshness/refresh policy lives in [ForumSessionManager].
/// Every write/clear also deletes the legacy [forumSecretStorageKey] so
/// installs upgrading from the client-minting era drop the shared
/// secret from the device.
class ForumSessionStore {
  ForumSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<ForumSession?> read() async {
    final String? token =
        await _storage.read(key: forumSessionTokenStorageKey);
    if (token == null || token.isEmpty) return null;
    final String? expiryRaw =
        await _storage.read(key: forumSessionExpiryStorageKey);
    final int? expirySeconds =
        expiryRaw == null ? null : int.tryParse(expiryRaw);
    if (expirySeconds == null) return null;
    return ForumSession(
      token: token,
      expiresAt:
          DateTime.fromMillisecondsSinceEpoch(expirySeconds * 1000, isUtc: true),
    );
  }

  Future<void> write(ForumSession session) async {
    await _storage.write(
      key: forumSessionTokenStorageKey,
      value: session.token,
    );
    await _storage.write(
      key: forumSessionExpiryStorageKey,
      value:
          '${session.expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000}',
    );
    await _storage.delete(key: forumSecretStorageKey);
  }

  Future<void> clear() async {
    await _storage.delete(key: forumSessionTokenStorageKey);
    await _storage.delete(key: forumSessionExpiryStorageKey);
    await _storage.delete(key: forumSecretStorageKey);
  }
}

/// Async producer of a fresh [ForumSession] when the stored one is
/// missing, expired, or rejected — production wires this to the silent
/// Google re-exchange (sign in silently → `POST /auth/google` → new
/// server-minted token). Returns null when refresh isn't possible
/// (no silent Google session, Google sign-in not configured for this
/// build, backend unreachable).
typedef ForumSessionRefresher = Future<ForumSession?> Function();

/// Owns the forum session token lifecycle: cache → secure storage →
/// silent refresh.
///
/// `currentToken()` policy:
///  * stored token fresh (expiry beyond [refreshAhead]) → use it;
///  * stored token inside the refresh window but unexpired → try
///    [refresher]; fall back to the stored token if refresh fails
///    (better a soon-to-expire token than none);
///  * missing/expired → [refresher] or [StateError]. Callers should
///    treat the StateError as "forum unreachable on this build/state"
///    and gate forum UI, exactly as the previous minter contract did.
///
/// Concurrent refreshes are deduped onto one in-flight future, so a
/// burst of API calls after expiry performs a single exchange.
class ForumSessionManager {
  ForumSessionManager({
    required ForumSessionStore store,
    required ForumSessionRefresher refresher,
    Duration refreshAhead = const Duration(days: 7),
    DateTime Function()? clock,
  })  : _store = store,
        _refresher = refresher,
        _refreshAhead = refreshAhead,
        _clock = clock ?? DateTime.now;

  final ForumSessionStore _store;
  final ForumSessionRefresher _refresher;
  final Duration _refreshAhead;
  final DateTime Function() _clock;

  ForumSession? _cached;
  Future<ForumSession?>? _inFlightRefresh;

  /// Adopt a session handed back by an explicit sign-in (`/auth/google`
  /// during the Google flow). Persists + caches it so the very next
  /// API call uses it without a storage read.
  Future<void> adoptSession(ForumSession session) async {
    _cached = session;
    await _store.write(session);
  }

  /// Bearer token for the Authorization header. See class docs for the
  /// freshness policy.
  Future<String> currentToken() async {
    final DateTime now = _clock();
    final ForumSession? stored = _cached ?? await _store.read();
    _cached = stored;

    if (stored != null && !stored.isExpired(now)) {
      final bool nearExpiry =
          !stored.expiresAt.isAfter(now.add(_refreshAhead));
      if (!nearExpiry) return stored.token;
      final ForumSession? refreshed = await _refresh();
      // Refresh failed but the stored token is still valid — use it.
      return (refreshed ?? stored).token;
    }

    final ForumSession? refreshed = await _refresh();
    if (refreshed != null) return refreshed.token;
    throw StateError(
      'No forum session token. Sign in with Google to establish one; '
      'forum surfaces should gate on auth state before calling.',
    );
  }

  /// The API client calls this when the Worker answered 401 +
  /// `Token-Expired: true`. Drops the dead token and attempts one
  /// refresh; returns true when a usable token now exists (the caller
  /// retries the original request once).
  Future<bool> recoverFromExpiry() async {
    _cached = null;
    await _store.clear();
    final ForumSession? refreshed = await _refresh();
    return refreshed != null;
  }

  /// Sign-out hook: forget the cached + persisted session (and, via
  /// [ForumSessionStore.clear], the legacy on-device secret).
  Future<void> clear() async {
    _cached = null;
    _inFlightRefresh = null;
    await _store.clear();
  }

  Future<ForumSession?> _refresh() {
    // Dedupe: concurrent callers share one exchange.
    final Future<ForumSession?> inFlight =
        _inFlightRefresh ??= _refreshOnce().whenComplete(() {
      _inFlightRefresh = null;
    });
    return inFlight;
  }

  Future<ForumSession?> _refreshOnce() async {
    final ForumSession? fresh;
    try {
      fresh = await _refresher();
    } catch (_) {
      // Refresh is best-effort: a transport/auth hiccup must not crash
      // the caller — currentToken() falls back / throws StateError.
      return null;
    }
    if (fresh == null || fresh.token.isEmpty) return null;
    _cached = fresh;
    await _store.write(fresh);
    return fresh;
  }
}

// ---------------------------------------------------------------------------
// Riverpod wiring
// ---------------------------------------------------------------------------

/// Production [ForumSessionStore]. `keepAlive: true` so secure-storage
/// reads are amortized across the app session.
@Riverpod(keepAlive: true)
ForumSessionStore forumSessionStore(Ref ref) => ForumSessionStore();

/// Production [ForumSessionManager].
///
/// The refresher runs the SILENT Google flow (no UI) and re-exchanges
/// the ID token at `POST /auth/google` for a fresh server-minted
/// session. It `ref.read`s the API client lazily at refresh time — not
/// at build — so there is no provider cycle with
/// `forumApiClientProvider` (which watches this manager for its token
/// loader; the `/auth/google` exchange itself is anonymous and never
/// re-enters the token path).
@Riverpod(keepAlive: true)
ForumSessionManager forumSessionManager(Ref ref) {
  final ForumSessionStore store = ref.watch(forumSessionStoreProvider);
  return ForumSessionManager(
    store: store,
    refresher: () async {
      // No Google client ids baked into this build (tests, demo) —
      // silent refresh is impossible by construction.
      if (!googleSignInConfigured) return null;
      final String? idToken = await silentGoogleIdToken();
      if (idToken == null || idToken.isEmpty) return null;
      final GoogleAuthResult result =
          await ref.read(forumApiClientProvider).verifyGoogleIdToken(idToken);
      final String? token = result.token;
      final int? expiresAt = result.tokenExpiresAt;
      if (token == null || token.isEmpty || expiresAt == null) return null;
      return ForumSession(
        token: token,
        expiresAt:
            DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000, isUtc: true),
      );
    },
  );
}

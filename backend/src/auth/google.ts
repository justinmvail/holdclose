// Server-side verification of Google ID tokens (OpenID Connect).
//
// Implemented entirely on Web Crypto (`crypto.subtle`) so it runs in the
// Workers runtime with no extra deps. The JWKS fetch + signature check are
// factored so callers can inject a `jwksFetcher` in tests (sign fixture
// tokens with a local RSA keypair, feed the matching public JWK through the
// seam) and never touch the network.

// Subset of a Google ID token's claims we rely on.
export type GoogleIdTokenClaims = {
  iss: string;
  sub: string;
  aud: string;
  exp: number;
  email?: string;
  email_verified?: boolean | string;
  name?: string;
};

export type VerifiedGoogleToken = {
  sub: string;
  email: string;
  name: string;
};

// A JWK as served by Google's certs endpoint.
type GoogleJwk = {
  kid: string;
  kty: string;
  alg: string;
  use?: string;
  n: string;
  e: string;
};

type GoogleCerts = {
  keys: GoogleJwk[];
};

const GOOGLE_CERTS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
const VALID_ISSUERS = new Set([
  'accounts.google.com',
  'https://accounts.google.com',
]);
// Clock-skew allowance applied to the `exp` check (seconds).
const CLOCK_SKEW_SECONDS = 60;

// Reasons surface only as opaque failure to the route (always 401), but the
// distinct cases keep the verifier testable + debuggable.
export class GoogleTokenError extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = 'GoogleTokenError';
  }
}

// Fetches Google's JWKS. The default impl hits the live certs endpoint and
// returns the keys plus the response's Cache-Control max-age (seconds) so
// the caller can cache. Tests inject a fetcher that returns a fixed JWK set.
export type JwksFetcher = () => Promise<{ keys: GoogleJwk[]; maxAgeSeconds: number }>;

export const defaultJwksFetcher: JwksFetcher = async () => {
  const res = await fetch(GOOGLE_CERTS_URL);
  if (!res.ok) {
    throw new GoogleTokenError('jwks_fetch_failed');
  }
  const body = (await res.json()) as GoogleCerts;
  const maxAgeSeconds = parseMaxAge(res.headers.get('Cache-Control'));
  return { keys: body.keys ?? [], maxAgeSeconds };
};

function parseMaxAge(cacheControl: string | null): number {
  if (!cacheControl) return 0;
  const match = /max-age=(\d+)/i.exec(cacheControl);
  if (!match) return 0;
  const value = Number(match[1]);
  return Number.isFinite(value) ? value : 0;
}

// Module-scope cache of fetched keys (Workers global scope persists across
// requests within an isolate). Keyed off the fetcher identity so an injected
// test fetcher never shares the live cache.
type CacheEntry = { keys: GoogleJwk[]; expiresAtMs: number };
const jwksCache = new WeakMap<JwksFetcher, CacheEntry>();

async function getKeys(
  fetcher: JwksFetcher,
  nowMs: number,
): Promise<GoogleJwk[]> {
  const cached = jwksCache.get(fetcher);
  if (cached && cached.expiresAtMs > nowMs) {
    return cached.keys;
  }
  const { keys, maxAgeSeconds } = await fetcher();
  jwksCache.set(fetcher, {
    keys,
    expiresAtMs: nowMs + maxAgeSeconds * 1000,
  });
  return keys;
}

function base64UrlToUint8Array(input: string): Uint8Array {
  const padded = input.replace(/-/g, '+').replace(/_/g, '/');
  const padLen = (4 - (padded.length % 4)) % 4;
  const base64 = padded + '='.repeat(padLen);
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function decodeJsonSegment<T>(segment: string): T {
  const bytes = base64UrlToUint8Array(segment);
  const text = new TextDecoder().decode(bytes);
  return JSON.parse(text) as T;
}

async function importRsaKey(jwk: GoogleJwk): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'jwk',
    {
      kty: jwk.kty,
      n: jwk.n,
      e: jwk.e,
      alg: 'RS256',
      ext: true,
    },
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  );
}

export type VerifyOptions = {
  // One or more allowed audiences (the configured web client id; optionally
  // additional ids such as a future iOS client id).
  clientIds: string[];
  // Injected for tests; defaults to the live Google certs endpoint.
  jwksFetcher?: JwksFetcher;
  // Injected for tests; defaults to `Date.now()`.
  now?: () => number;
};

// Verifies a Google ID token end-to-end: RS256 signature against Google's
// JWKS, then the iss / aud / exp / email_verified claims. Throws
// `GoogleTokenError` on any failure; returns the trusted subset on success.
export async function verifyGoogleIdToken(
  token: string,
  options: VerifyOptions,
): Promise<VerifiedGoogleToken> {
  const nowMs = (options.now ?? Date.now)();
  const nowSec = Math.floor(nowMs / 1000);
  const fetcher = options.jwksFetcher ?? defaultJwksFetcher;

  if (typeof token !== 'string' || token.length === 0) {
    throw new GoogleTokenError('malformed_token');
  }
  const parts = token.split('.');
  if (parts.length !== 3) {
    throw new GoogleTokenError('malformed_token');
  }
  const [headerSeg, payloadSeg, signatureSeg] = parts;

  let header: { kid?: string; alg?: string };
  let claims: GoogleIdTokenClaims;
  try {
    header = decodeJsonSegment<{ kid?: string; alg?: string }>(headerSeg);
    claims = decodeJsonSegment<GoogleIdTokenClaims>(payloadSeg);
  } catch {
    throw new GoogleTokenError('malformed_token');
  }

  if (header.alg !== 'RS256') {
    throw new GoogleTokenError('unexpected_alg');
  }
  if (!header.kid) {
    throw new GoogleTokenError('missing_kid');
  }

  const keys = await getKeys(fetcher, nowMs);
  const jwk = keys.find((k) => k.kid === header.kid);
  if (!jwk) {
    throw new GoogleTokenError('unknown_kid');
  }

  const key = await importRsaKey(jwk);
  const signedData = new TextEncoder().encode(`${headerSeg}.${payloadSeg}`);
  const signature = base64UrlToUint8Array(signatureSeg);
  const valid = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    signature,
    signedData,
  );
  if (!valid) {
    throw new GoogleTokenError('bad_signature');
  }

  // Claim validation (only after the signature is trusted).
  if (typeof claims.iss !== 'string' || !VALID_ISSUERS.has(claims.iss)) {
    throw new GoogleTokenError('bad_issuer');
  }
  if (typeof claims.aud !== 'string' || !options.clientIds.includes(claims.aud)) {
    throw new GoogleTokenError('bad_audience');
  }
  if (typeof claims.exp !== 'number' || claims.exp + CLOCK_SKEW_SECONDS < nowSec) {
    throw new GoogleTokenError('expired');
  }
  // Reject only when email_verified is *explicitly* false ("false" string or
  // boolean false). Absent → not rejected.
  if (claims.email_verified === false || claims.email_verified === 'false') {
    throw new GoogleTokenError('email_unverified');
  }
  if (typeof claims.sub !== 'string' || claims.sub.length === 0) {
    throw new GoogleTokenError('missing_sub');
  }

  return {
    sub: claims.sub,
    email: typeof claims.email === 'string' ? claims.email : '',
    name: typeof claims.name === 'string' ? claims.name : '',
  };
}

// Parses the configured GOOGLE_CLIENT_ID (single value or comma-separated
// list) into the allowed-audience array.
export function parseClientIds(raw: string | undefined): string[] {
  if (!raw) return [];
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

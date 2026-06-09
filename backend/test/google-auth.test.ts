import { env } from 'cloudflare:test';
import { drizzle } from 'drizzle-orm/d1';
import { eq } from 'drizzle-orm';
import { Hono } from 'hono';
import { beforeEach, describe, expect, it } from 'vitest';

import {
  GoogleTokenError,
  parseClientIds,
  verifyGoogleIdToken,
  type JwksFetcher,
} from '../src/auth/google';
import { authRouter, type AuthRouteBindings } from '../src/routes/auth';
import { profiles } from '../src/db/schema';

const CLIENT_ID = 'test-google-web-client-id.apps.googleusercontent.com';
const KID = 'test-kid-1';
const ISS = 'https://accounts.google.com';

// ---- Local RSA keypair + JWT fixture signing (no real Google) ----

function uint8ToBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function jsonToBase64Url(obj: unknown): string {
  return uint8ToBase64Url(new TextEncoder().encode(JSON.stringify(obj)));
}

async function generateKeypair() {
  const pair = await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([0x01, 0x00, 0x01]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  );
  return pair as CryptoKeyPair;
}

// Export the public key as a JWK shaped like Google's certs entries.
async function publicJwk(key: CryptoKey, kid: string) {
  const jwk = (await crypto.subtle.exportKey('jwk', key)) as JsonWebKey;
  return {
    kid,
    kty: jwk.kty as string,
    alg: 'RS256',
    use: 'sig',
    n: jwk.n as string,
    e: jwk.e as string,
  };
}

type Claims = {
  iss?: string;
  sub?: string;
  aud?: string;
  exp?: number;
  email?: string;
  email_verified?: boolean | string;
  name?: string;
};

const nowSec = () => Math.floor(Date.now() / 1000);

async function signToken(
  privateKey: CryptoKey,
  claims: Claims,
  opts: { kid?: string; alg?: string } = {},
): Promise<string> {
  const header = { alg: opts.alg ?? 'RS256', kid: opts.kid ?? KID, typ: 'JWT' };
  const fullClaims: Claims = {
    iss: ISS,
    aud: CLIENT_ID,
    exp: nowSec() + 3600,
    ...claims,
  };
  const headerSeg = jsonToBase64Url(header);
  const payloadSeg = jsonToBase64Url(fullClaims);
  const signingInput = `${headerSeg}.${payloadSeg}`;
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    privateKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${uint8ToBase64Url(new Uint8Array(sig))}`;
}

// Per-test world: a keypair + a JWKS fetcher serving its public key. A unique
// fetcher identity per call avoids sharing the module-scope JWKS cache.
async function makeWorld(opts: { kid?: string } = {}) {
  const kid = opts.kid ?? KID;
  const pair = await generateKeypair();
  const jwk = await publicJwk(pair.publicKey, kid);
  const jwksFetcher: JwksFetcher = async () => ({
    keys: [jwk],
    maxAgeSeconds: 3600,
  });
  return { pair, jwksFetcher };
}

// ---- Verifier unit tests ----

describe('verifyGoogleIdToken', () => {
  it('accepts a valid token and returns sub/email/name', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'google-sub-1',
      email: 'sarah@example.com',
      email_verified: true,
      name: 'Sarah H',
    });
    const result = await verifyGoogleIdToken(token, {
      clientIds: [CLIENT_ID],
      jwksFetcher,
    });
    expect(result).toEqual({
      sub: 'google-sub-1',
      email: 'sarah@example.com',
      name: 'Sarah H',
    });
  });

  it('accepts the bare accounts.google.com issuer', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      iss: 'accounts.google.com',
      sub: 'google-sub-iss',
    });
    const result = await verifyGoogleIdToken(token, {
      clientIds: [CLIENT_ID],
      jwksFetcher,
    });
    expect(result.sub).toBe('google-sub-iss');
  });

  it('accepts a token whose aud matches ANY configured client id', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'google-sub-ios',
      aud: 'ios-client-id.apps.googleusercontent.com',
    });
    const result = await verifyGoogleIdToken(token, {
      clientIds: [CLIENT_ID, 'ios-client-id.apps.googleusercontent.com'],
      jwksFetcher,
    });
    expect(result.sub).toBe('google-sub-ios');
  });

  it('rejects a wrong audience', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'x',
      aud: 'some-other-client.apps.googleusercontent.com',
    });
    await expect(
      verifyGoogleIdToken(token, { clientIds: [CLIENT_ID], jwksFetcher }),
    ).rejects.toBeInstanceOf(GoogleTokenError);
  });

  it('rejects an expired token (beyond the skew allowance)', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'x',
      exp: nowSec() - 3600,
    });
    await expect(
      verifyGoogleIdToken(token, { clientIds: [CLIENT_ID], jwksFetcher }),
    ).rejects.toBeInstanceOf(GoogleTokenError);
  });

  it('allows a token within the 60s clock-skew window', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'skew',
      exp: nowSec() - 30,
    });
    const result = await verifyGoogleIdToken(token, {
      clientIds: [CLIENT_ID],
      jwksFetcher,
    });
    expect(result.sub).toBe('skew');
  });

  it('rejects a bad signature (key mismatch / unknown kid)', async () => {
    const signer = await makeWorld({ kid: 'kid-A' });
    const verifierWorld = await makeWorld({ kid: 'kid-A' });
    // Sign with signer's private key but verify against a DIFFERENT public
    // key advertised under the same kid → signature check fails.
    const token = await signToken(
      signer.pair.privateKey,
      { sub: 'x' },
      { kid: 'kid-A' },
    );
    await expect(
      verifyGoogleIdToken(token, {
        clientIds: [CLIENT_ID],
        jwksFetcher: verifierWorld.jwksFetcher,
      }),
    ).rejects.toBeInstanceOf(GoogleTokenError);
  });

  it('rejects when no JWK matches the token kid', async () => {
    const { pair, jwksFetcher } = await makeWorld({ kid: 'served-kid' });
    const token = await signToken(
      pair.privateKey,
      { sub: 'x' },
      { kid: 'different-kid' },
    );
    await expect(
      verifyGoogleIdToken(token, { clientIds: [CLIENT_ID], jwksFetcher }),
    ).rejects.toBeInstanceOf(GoogleTokenError);
  });

  it('rejects when email_verified is explicitly false', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'x',
      email_verified: false,
    });
    await expect(
      verifyGoogleIdToken(token, { clientIds: [CLIENT_ID], jwksFetcher }),
    ).rejects.toBeInstanceOf(GoogleTokenError);
  });

  it('rejects a malformed (non-3-part) token', async () => {
    const { jwksFetcher } = await makeWorld();
    await expect(
      verifyGoogleIdToken('not.a', { clientIds: [CLIENT_ID], jwksFetcher }),
    ).rejects.toBeInstanceOf(GoogleTokenError);
  });
});

describe('parseClientIds', () => {
  it('parses a single value', () => {
    expect(parseClientIds('one.apps')).toEqual(['one.apps']);
  });
  it('parses a comma-separated list and trims', () => {
    expect(parseClientIds(' a , b ,c ')).toEqual(['a', 'b', 'c']);
  });
  it('returns [] for undefined/empty', () => {
    expect(parseClientIds(undefined)).toEqual([]);
    expect(parseClientIds('')).toEqual([]);
  });
});

// ---- Route integration tests (POST /api/v1/auth/google) ----

function makeApp(jwksFetcher: JwksFetcher) {
  const app = new Hono<{ Bindings: AuthRouteBindings }>();
  app.route('/api/v1/auth', authRouter(jwksFetcher));
  return app;
}

const ROUTE_ENV = () => ({
  FORUM_DB: env.FORUM_DB,
  GOOGLE_CLIENT_ID: CLIENT_ID,
});

async function postGoogle(
  app: Hono<{ Bindings: AuthRouteBindings }>,
  body: unknown,
) {
  return app.request(
    '/api/v1/auth/google',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    },
    ROUTE_ENV(),
  );
}

describe('POST /api/v1/auth/google', () => {
  beforeEach(async () => {
    await env.FORUM_DB.prepare('DELETE FROM profiles').run();
  });

  it('returns 400 missing_id_token when body lacks id_token', async () => {
    const { jwksFetcher } = await makeWorld();
    const res = await postGoogle(makeApp(jwksFetcher), {});
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'missing_id_token' });
  });

  it('returns 400 missing_id_token when body is not JSON', async () => {
    const { jwksFetcher } = await makeWorld();
    const res = await makeApp(jwksFetcher).request(
      '/api/v1/auth/google',
      { method: 'POST', body: 'not-json' },
      ROUTE_ENV(),
    );
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'missing_id_token' });
  });

  it('verifies a valid token, provisions a profile, returns the contract shape', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'google-sub-new',
      email: 'new@example.com',
      email_verified: true,
      name: 'New Caregiver',
    });
    const res = await postGoogle(makeApp(jwksFetcher), { id_token: token });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      user_id: 'google-sub-new',
      email: 'new@example.com',
      name: 'New Caregiver',
      username: null,
    });

    const rows = await drizzle(env.FORUM_DB)
      .select()
      .from(profiles)
      .where(eq(profiles.careblazersUserId, 'google-sub-new'));
    expect(rows).toHaveLength(1);
    expect(rows[0].displayName).toBe('New Caregiver');
  });

  it('falls back to the default display name when the token name is absent', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'google-sub-noname',
      email: 'noname@example.com',
      email_verified: true,
    });
    const res = await postGoogle(makeApp(jwksFetcher), { id_token: token });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { name: string };
    expect(body.name).toBe('');

    const rows = await drizzle(env.FORUM_DB)
      .select()
      .from(profiles)
      .where(eq(profiles.careblazersUserId, 'google-sub-noname'));
    expect(rows[0].displayName).toMatch(/^Caregiver_[0-9a-f]{6}$/);
  });

  it('leaves an existing profile untouched and returns its current username', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    // Pre-existing profile with a custom display name + username.
    await drizzle(env.FORUM_DB)
      .insert(profiles)
      .values({
        displayName: 'Existing_Name',
        username: 'existing_handle',
        careblazersUserId: 'google-sub-existing',
      });

    const token = await signToken(pair.privateKey, {
      sub: 'google-sub-existing',
      email: 'existing@example.com',
      email_verified: true,
      name: 'Should Not Overwrite',
    });
    const res = await postGoogle(makeApp(jwksFetcher), { id_token: token });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      user_id: 'google-sub-existing',
      email: 'existing@example.com',
      name: 'Should Not Overwrite',
      username: 'existing_handle',
    });

    const rows = await drizzle(env.FORUM_DB)
      .select()
      .from(profiles)
      .where(eq(profiles.careblazersUserId, 'google-sub-existing'));
    expect(rows).toHaveLength(1);
    // Display name preserved — not overwritten by the token's name.
    expect(rows[0].displayName).toBe('Existing_Name');
  });

  it('returns 401 invalid_token for a wrong audience', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'x',
      aud: 'wrong.apps.googleusercontent.com',
    });
    const res = await postGoogle(makeApp(jwksFetcher), { id_token: token });
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: 'invalid_token' });
  });

  it('returns 401 invalid_token for an expired token', async () => {
    const { pair, jwksFetcher } = await makeWorld();
    const token = await signToken(pair.privateKey, {
      sub: 'x',
      exp: nowSec() - 3600,
    });
    const res = await postGoogle(makeApp(jwksFetcher), { id_token: token });
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: 'invalid_token' });
  });

  it('returns 401 invalid_token for a bad signature', async () => {
    const signer = await makeWorld({ kid: 'shared-kid' });
    const verifierWorld = await makeWorld({ kid: 'shared-kid' });
    const token = await signToken(
      signer.pair.privateKey,
      { sub: 'x' },
      { kid: 'shared-kid' },
    );
    const res = await postGoogle(makeApp(verifierWorld.jwksFetcher), {
      id_token: token,
    });
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: 'invalid_token' });
  });
});

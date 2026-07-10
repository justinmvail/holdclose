import { SELF, env, fetchMock } from 'cloudflare:test';
import { drizzle } from 'drizzle-orm/d1';
import { eq } from 'drizzle-orm';
import { Hono } from 'hono';
import { sign } from 'hono/jwt';
import {
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from 'vitest';

import { entitlements } from '../src/db/schema';
import {
  billingRouter,
  type BillingBindings,
} from '../src/routes/billing';
import {
  AppleVerifier,
  FakeVerifier,
  GoogleVerifier,
  InvalidReceiptError,
  StoreUnavailableError,
  normalizeApple,
  normalizeGoogle,
  type VerifiedPurchase,
} from '../src/billing/verifier';
import { auth } from '../src/middleware/auth';

const SECRET = env.FORUM_JWT_SECRET;

const nowSec = () => Math.floor(Date.now() / 1000);
const HOUR = 60 * 60 * 1000;

async function mintToken(sub: string) {
  const iat = nowSec();
  return sign({ sub, iat, exp: iat + 3600 }, SECRET, 'HS256');
}

// ---- Route harness: a local app wiring the (auth + billing) routers so we
// can inject a FakeVerifier, exactly like google-auth.test.ts builds its own
// app to inject a jwksFetcher. env carries the real D1 binding. ----

function makeApp(injected?: {
  apple?: FakeVerifier;
  google?: FakeVerifier;
}) {
  const app = new Hono<{
    Bindings: BillingBindings;
    Variables: { userId: string };
  }>();
  app.use('/api/v1/billing/*', auth());
  app.route('/api/v1/billing', billingRouter(injected));
  return app;
}

// Env with NO store creds by default (so the misconfigured path is
// reachable) — the injected FakeVerifier stands in for the store.
const ROUTE_ENV = () => ({ FORUM_DB: env.FORUM_DB, FORUM_JWT_SECRET: SECRET });

async function verify(
  app: Hono<{ Bindings: BillingBindings; Variables: { userId: string } }>,
  sub: string | null,
  body: unknown,
) {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (sub !== null) headers.Authorization = `Bearer ${await mintToken(sub)}`;
  return app.request(
    '/api/v1/billing/verify',
    { method: 'POST', headers, body: JSON.stringify(body) },
    ROUTE_ENV(),
  );
}

async function getEntitlement(
  app: Hono<{ Bindings: BillingBindings; Variables: { userId: string } }>,
  sub: string,
) {
  return app.request(
    '/api/v1/billing/entitlement',
    { headers: { Authorization: `Bearer ${await mintToken(sub)}` } },
    ROUTE_ENV(),
  );
}

async function clearEntitlements() {
  await env.FORUM_DB.prepare('DELETE FROM entitlements').run();
}

async function rowFor(userId: string) {
  return drizzle(env.FORUM_DB)
    .select()
    .from(entitlements)
    .where(eq(entitlements.userId, userId));
}

const activePurchase = (over: Partial<VerifiedPurchase> = {}): VerifiedPurchase => ({
  active: true,
  productId: 'com.holdclose.premium.monthly',
  expiresAtMs: Date.now() + 30 * 24 * HOUR,
  isTrial: false,
  environment: 'production',
  ...over,
});

beforeEach(async () => {
  await clearEntitlements();
});

// ===========================================================================
// Verifier normalization units (pure, no fetch)
// ===========================================================================

describe('normalizeApple', () => {
  it('maps an active auto-renewable subscription', () => {
    const r = normalizeApple({
      productId: 'com.holdclose.premium.monthly',
      type: 'Auto-Renewable Subscription',
      expiresDate: Date.now() + HOUR,
      environment: 'Production',
    });
    expect(r).toEqual({
      active: true,
      productId: 'com.holdclose.premium.monthly',
      expiresAtMs: expect.any(Number),
      isTrial: false,
      environment: 'production',
    });
  });

  it('marks an expired subscription inactive', () => {
    const r = normalizeApple({
      productId: 'p',
      type: 'Auto-Renewable Subscription',
      expiresDate: Date.now() - HOUR,
      environment: 'Sandbox',
    });
    expect(r.active).toBe(false);
    expect(r.environment).toBe('sandbox');
  });

  it('flags an introductory free trial', () => {
    const r = normalizeApple({
      productId: 'p',
      type: 'Auto-Renewable Subscription',
      expiresDate: Date.now() + HOUR,
      environment: 'Production',
      offerType: 1,
    });
    expect(r.isTrial).toBe(true);
    expect(r.active).toBe(true);
  });
});

describe('normalizeGoogle', () => {
  it('maps an ACTIVE subscription state with a future expiry', () => {
    const r = normalizeGoogle(
      {
        subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
        lineItems: [
          {
            productId: 'com.holdclose.premium.monthly',
            expiryTime: new Date(Date.now() + HOUR).toISOString(),
          },
        ],
      },
      'com.holdclose.premium.monthly',
    );
    expect(r.active).toBe(true);
    expect(r.productId).toBe('com.holdclose.premium.monthly');
    expect(r.environment).toBe('production');
  });

  it('marks an EXPIRED state inactive', () => {
    const r = normalizeGoogle(
      {
        subscriptionState: 'SUBSCRIPTION_STATE_EXPIRED',
        lineItems: [
          { productId: 'p', expiryTime: new Date(Date.now() - HOUR).toISOString() },
        ],
      },
      'p',
    );
    expect(r.active).toBe(false);
  });

  it('flags a trial state and a test purchase as sandbox', () => {
    const r = normalizeGoogle(
      {
        subscriptionState: 'SUBSCRIPTION_STATE_IN_TRIAL',
        testPurchase: {},
        lineItems: [
          { productId: 'p', expiryTime: new Date(Date.now() + HOUR).toISOString() },
        ],
      },
      'p',
    );
    expect(r.isTrial).toBe(true);
    expect(r.active).toBe(true);
    expect(r.environment).toBe('sandbox');
  });
});

// ===========================================================================
// POST /billing/verify + GET /billing/entitlement (FakeVerifier injected)
// ===========================================================================

describe('POST /api/v1/billing/verify (iOS, faked store)', () => {
  it('verifies, upserts the entitlement, returns isPremium:true', async () => {
    const receipt = 'apple-jws-good';
    const app = makeApp({
      apple: new FakeVerifier({ apple: { [receipt]: activePurchase() } }),
    });
    const res = await verify(app, 'user-ios', {
      platform: 'ios',
      productId: 'com.holdclose.premium.monthly',
      receipt,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      isPremium: true,
      inTrial: false,
      expiresAt: expect.any(Number),
      productId: 'com.holdclose.premium.monthly',
      platform: 'ios',
    });

    const rows = await rowFor('user-ios');
    expect(rows).toHaveLength(1);
    expect(rows[0].platform).toBe('ios');
    expect(rows[0].status).toBe('active');
    expect(rows[0].latestReceipt).toBe(receipt);
    expect(rows[0].environment).toBe('production');
  });

  it('records a trial purchase as inTrial:true', async () => {
    const receipt = 'apple-jws-trial';
    const app = makeApp({
      apple: new FakeVerifier({
        apple: { [receipt]: activePurchase({ isTrial: true }) },
      }),
    });
    const res = await verify(app, 'user-trial', {
      platform: 'ios',
      productId: 'com.holdclose.premium.monthly',
      receipt,
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ isPremium: true, inTrial: true });
    const rows = await rowFor('user-trial');
    expect(rows[0].status).toBe('trial');
  });

  it('an expired (inactive) receipt → isPremium:false, status expired', async () => {
    const receipt = 'apple-jws-expired';
    const app = makeApp({
      apple: new FakeVerifier({
        apple: {
          [receipt]: activePurchase({
            active: false,
            expiresAtMs: Date.now() - HOUR,
          }),
        },
      }),
    });
    const res = await verify(app, 'user-expired', {
      platform: 'ios',
      productId: 'com.holdclose.premium.monthly',
      receipt,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ isPremium: false, inTrial: false });
    const rows = await rowFor('user-expired');
    expect(rows[0].status).toBe('expired');
  });

  it('re-verify UPSERTS the same row (one row per user)', async () => {
    const app = makeApp({
      apple: new FakeVerifier({
        apple: {
          r1: activePurchase({ productId: 'a' }),
          r2: activePurchase({ productId: 'b' }),
        },
      }),
    });
    await verify(app, 'user-upsert', { platform: 'ios', productId: 'a', receipt: 'r1' });
    await verify(app, 'user-upsert', { platform: 'ios', productId: 'b', receipt: 'r2' });
    const rows = await rowFor('user-upsert');
    expect(rows).toHaveLength(1);
    expect(rows[0].productId).toBe('b');
    expect(rows[0].latestReceipt).toBe('r2');
  });
});

describe('POST /api/v1/billing/verify (Android, faked store)', () => {
  it('verifies a Google purchase and upserts', async () => {
    const token = 'google-purchase-token';
    const app = makeApp({
      google: new FakeVerifier({
        google: {
          [token]: activePurchase({
            productId: 'com.holdclose.premium.annual',
          }),
        },
      }),
    });
    const res = await verify(app, 'user-android', {
      platform: 'android',
      productId: 'com.holdclose.premium.annual',
      receipt: token,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({
      isPremium: true,
      productId: 'com.holdclose.premium.annual',
      platform: 'android',
    });
    const rows = await rowFor('user-android');
    expect(rows).toHaveLength(1);
    expect(rows[0].platform).toBe('android');
  });
});

describe('POST /api/v1/billing/verify — error surfaces', () => {
  it('401 for an unauthenticated caller', async () => {
    const app = makeApp({ apple: new FakeVerifier() });
    const res = await verify(app, null, {
      platform: 'ios',
      productId: 'p',
      receipt: 'r',
    });
    expect(res.status).toBe(401);
  });

  it('400 for a missing/blank body field', async () => {
    const app = makeApp({ apple: new FakeVerifier() });
    for (const body of [
      { productId: 'p', receipt: 'r' }, // no platform
      { platform: 'ios', receipt: 'r' }, // no productId
      { platform: 'ios', productId: 'p' }, // no receipt
      { platform: 'windows', productId: 'p', receipt: 'r' }, // bad platform
      { platform: 'ios', productId: '', receipt: 'r' }, // empty productId
    ]) {
      const res = await verify(app, 'user-bad', body);
      expect(res.status).toBe(400);
    }
  });

  it('400 for a non-JSON body', async () => {
    const app = makeApp({ apple: new FakeVerifier() });
    const res = await app.request(
      '/api/v1/billing/verify',
      {
        method: 'POST',
        headers: { Authorization: `Bearer ${await mintToken('u')}` },
        body: 'not-json',
      },
      ROUTE_ENV(),
    );
    expect(res.status).toBe(400);
  });

  it('200 + isPremium:false for a well-formed but INVALID receipt (no 500)', async () => {
    // FakeVerifier with no scripted receipt → InvalidReceiptError.
    const app = makeApp({ apple: new FakeVerifier({ apple: {} }) });
    const res = await verify(app, 'user-invalid', {
      platform: 'ios',
      productId: 'p',
      receipt: 'unknown-receipt',
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      isPremium: false,
      inTrial: false,
      expiresAt: null,
      productId: 'p',
      platform: 'ios',
    });
    // A 'none' row is persisted so GET reflects the (lack of) entitlement.
    const rows = await rowFor('user-invalid');
    expect(rows).toHaveLength(1);
    expect(rows[0].status).toBe('none');
  });

  it('502 when the store API is unreachable', async () => {
    const app = makeApp({ apple: new FakeVerifier({ unavailable: true }) });
    const res = await verify(app, 'user-502', {
      platform: 'ios',
      productId: 'p',
      receipt: 'r',
    });
    expect(res.status).toBe(502);
    expect(await res.json()).toEqual({ error: 'store_unavailable' });
  });

  it('500 server_misconfigured when the platform creds are absent', async () => {
    // No injected verifier + no creds in env → the platform verifier can't
    // be built.
    const app = makeApp();
    const res = await verify(app, 'user-misc', {
      platform: 'ios',
      productId: 'p',
      receipt: 'r',
    });
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'server_misconfigured' });
  });
});

describe('GET /api/v1/billing/entitlement', () => {
  it('defaults to {isPremium:false} when no row exists', async () => {
    const app = makeApp();
    const res = await getEntitlement(app, 'user-none');
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      isPremium: false,
      inTrial: false,
      expiresAt: null,
      productId: null,
    });
  });

  it('reflects the stored authoritative entitlement after a verify', async () => {
    const receipt = 'apple-jws-store';
    const app = makeApp({
      apple: new FakeVerifier({ apple: { [receipt]: activePurchase() } }),
    });
    await verify(app, 'user-get', {
      platform: 'ios',
      productId: 'com.holdclose.premium.monthly',
      receipt,
    });
    const res = await getEntitlement(app, 'user-get');
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({
      isPremium: true,
      inTrial: false,
      productId: 'com.holdclose.premium.monthly',
    });
  });

  it('reads not-premium once a stored row has aged past its expiry', async () => {
    // Persist an "active" row whose expiry is already in the past; isPremium
    // is DERIVED, so it must read false even without a re-verify.
    const now = new Date();
    await drizzle(env.FORUM_DB)
      .insert(entitlements)
      .values({
        userId: 'user-aged',
        platform: 'ios',
        productId: 'p',
        status: 'active',
        expiresAt: Date.now() - HOUR,
        environment: 'production',
        latestReceipt: 'r',
        createdAt: now,
        updatedAt: now,
      });
    const res = await getEntitlement(makeApp(), 'user-aged');
    expect((await res.json()) as unknown).toMatchObject({ isPremium: false });
  });

  it('401 for an unauthenticated caller', async () => {
    const app = makeApp();
    const res = await app.request(
      '/api/v1/billing/entitlement',
      {},
      ROUTE_ENV(),
    );
    expect(res.status).toBe(401);
  });
});

// ===========================================================================
// Routes ARE mounted in the real worker under /api/v1/billing (SELF.fetch).
// This proves index.ts wiring + JWT gating without exercising real creds
// (the real worker has no store creds under test → 500 misconfigured, which
// is exactly the "creds absent" contract).
// ===========================================================================

describe('billing routes mounted in the worker (SELF.fetch)', () => {
  it('GET entitlement is JWT-gated and defaults to not-premium', async () => {
    const token = await mintToken('self-user');
    const res = await SELF.fetch(
      'https://forum.holdclose.local/api/v1/billing/entitlement',
      { headers: { Authorization: `Bearer ${token}` } },
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      isPremium: false,
      inTrial: false,
      expiresAt: null,
      productId: null,
    });
  });

  it('GET entitlement rejects an unauthenticated caller', async () => {
    const res = await SELF.fetch(
      'https://forum.holdclose.local/api/v1/billing/entitlement',
    );
    expect(res.status).toBe(401);
  });

  it('POST verify answers 500 when the worker has no store creds', async () => {
    const token = await mintToken('self-user-2');
    const res = await SELF.fetch(
      'https://forum.holdclose.local/api/v1/billing/verify',
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ platform: 'ios', productId: 'p', receipt: 'r' }),
      },
    );
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: 'server_misconfigured' });
  });
});

// ===========================================================================
// Real AppleVerifier / GoogleVerifier over a MOCKED store (no real creds).
// A locally-generated EC/RSA private key signs the request JWT; fetchMock
// stands in for Apple's transactions endpoint and Google's OAuth + purchases
// endpoints. This exercises the actual store-parsing code paths.
// ===========================================================================

const APPLE_HOST = 'https://api.storekit.itunes.apple.com';
const GOOGLE_TOKEN_HOST = 'https://oauth2.googleapis.com';
const GOOGLE_API_HOST = 'https://androidpublisher.googleapis.com';

function b64url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function jwsWithPayload(payload: unknown): string {
  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: 'ES256' })));
  const body = b64url(new TextEncoder().encode(JSON.stringify(payload)));
  // Signature is never verified by our decoder (Apple's TLS is the trust
  // boundary), so a fixed placeholder is fine.
  return `${header}.${body}.c2ln`;
}

async function ecPrivatePkcs8Pem(): Promise<string> {
  const pair = (await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  )) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(
    (await crypto.subtle.exportKey('pkcs8', pair.privateKey)) as ArrayBuffer,
  );
  return `-----BEGIN PRIVATE KEY-----\n${btoa(
    String.fromCharCode(...pkcs8),
  ).replace(/(.{64})/g, '$1\n')}\n-----END PRIVATE KEY-----`;
}

async function rsaPrivatePkcs8Pem(): Promise<string> {
  const pair = (await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([0x01, 0x00, 0x01]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  )) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(
    (await crypto.subtle.exportKey('pkcs8', pair.privateKey)) as ArrayBuffer,
  );
  return `-----BEGIN PRIVATE KEY-----\n${btoa(
    String.fromCharCode(...pkcs8),
  ).replace(/(.{64})/g, '$1\n')}\n-----END PRIVATE KEY-----`;
}

describe('AppleVerifier over a mocked App Store Server API', () => {
  beforeAll(() => {
    fetchMock.activate();
    fetchMock.disableNetConnect();
  });
  afterEach(() => {
    fetchMock.assertNoPendingInterceptors();
  });

  it('signs a request JWT, calls the transactions endpoint, parses the JWS', async () => {
    const pem = await ecPrivatePkcs8Pem();
    const txId = 'tx-12345';
    const clientJws = jwsWithPayload({ transactionId: txId });
    const signedTransactionInfo = jwsWithPayload({
      transactionId: txId,
      productId: 'com.holdclose.premium.monthly',
      type: 'Auto-Renewable Subscription',
      expiresDate: Date.now() + 30 * 24 * HOUR,
      environment: 'Production',
    });

    fetchMock
      .get(APPLE_HOST)
      .intercept({ path: `/inApps/v1/transactions/${txId}`, method: 'GET' })
      .reply(200, { signedTransactionInfo });

    const verifier = new AppleVerifier({
      issuerId: 'issuer-uuid',
      keyId: 'ABC123',
      privateKey: pem,
      bundleId: 'com.holdclose.holdclose',
    });
    const r = await verifier.verifyApple(clientJws, 'production');
    expect(r.active).toBe(true);
    expect(r.productId).toBe('com.holdclose.premium.monthly');
    expect(r.environment).toBe('production');
  });

  it('throws InvalidReceiptError on a 404 (unknown transaction)', async () => {
    const pem = await ecPrivatePkcs8Pem();
    const clientJws = jwsWithPayload({ transactionId: 'gone' });
    fetchMock
      .get(APPLE_HOST)
      .intercept({ path: '/inApps/v1/transactions/gone', method: 'GET' })
      .reply(404, {});
    const verifier = new AppleVerifier({
      issuerId: 'i',
      keyId: 'k',
      privateKey: pem,
      bundleId: 'b',
    });
    await expect(verifier.verifyApple(clientJws, 'production')).rejects.toBeInstanceOf(
      InvalidReceiptError,
    );
  });

  it('throws StoreUnavailableError on a 5xx', async () => {
    const pem = await ecPrivatePkcs8Pem();
    const clientJws = jwsWithPayload({ transactionId: 'boom' });
    fetchMock
      .get(APPLE_HOST)
      .intercept({ path: '/inApps/v1/transactions/boom', method: 'GET' })
      .reply(503, {});
    const verifier = new AppleVerifier({
      issuerId: 'i',
      keyId: 'k',
      privateKey: pem,
      bundleId: 'b',
    });
    await expect(verifier.verifyApple(clientJws, 'production')).rejects.toBeInstanceOf(
      StoreUnavailableError,
    );
  });
});

describe('GoogleVerifier over a mocked Play Developer API', () => {
  beforeAll(() => {
    fetchMock.activate();
    fetchMock.disableNetConnect();
  });
  afterEach(() => {
    fetchMock.assertNoPendingInterceptors();
  });

  it('exchanges a SA JWT for a token, then reads the subscription', async () => {
    const pem = await rsaPrivatePkcs8Pem();
    const purchaseToken = 'ptoken-abc';
    const pkg = 'com.holdclose.holdclose';

    fetchMock
      .get(GOOGLE_TOKEN_HOST)
      .intercept({ path: '/token', method: 'POST' })
      .reply(200, { access_token: 'ya29.fake', expires_in: 3599 });

    fetchMock
      .get(GOOGLE_API_HOST)
      .intercept({
        path: `/androidpublisher/v3/applications/${pkg}/purchases/subscriptionsv2/tokens/${purchaseToken}`,
        method: 'GET',
      })
      .reply(200, {
        subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
        lineItems: [
          {
            productId: 'com.holdclose.premium.annual',
            expiryTime: new Date(Date.now() + 365 * 24 * HOUR).toISOString(),
          },
        ],
      });

    const verifier = new GoogleVerifier({
      serviceAccountEmail: 'sa@project.iam.gserviceaccount.com',
      privateKey: pem,
      packageName: pkg,
    });
    const r = await verifier.verifyGoogle(
      'com.holdclose.premium.annual',
      purchaseToken,
      'production',
    );
    expect(r.active).toBe(true);
    expect(r.productId).toBe('com.holdclose.premium.annual');
  });

  it('throws InvalidReceiptError when Google returns 410 for the token', async () => {
    const pem = await rsaPrivatePkcs8Pem();
    const purchaseToken = 'ptoken-gone';
    const pkg = 'com.holdclose.holdclose';

    fetchMock
      .get(GOOGLE_TOKEN_HOST)
      .intercept({ path: '/token', method: 'POST' })
      .reply(200, { access_token: 'ya29.fake' });
    fetchMock
      .get(GOOGLE_API_HOST)
      .intercept({
        path: `/androidpublisher/v3/applications/${pkg}/purchases/subscriptionsv2/tokens/${purchaseToken}`,
        method: 'GET',
      })
      .reply(410, {});

    const verifier = new GoogleVerifier({
      serviceAccountEmail: 'sa@project.iam.gserviceaccount.com',
      privateKey: pem,
      packageName: pkg,
    });
    await expect(
      verifier.verifyGoogle('p', purchaseToken, 'production'),
    ).rejects.toBeInstanceOf(InvalidReceiptError);
  });

  it('throws StoreUnavailableError when the OAuth exchange fails', async () => {
    const pem = await rsaPrivatePkcs8Pem();
    fetchMock
      .get(GOOGLE_TOKEN_HOST)
      .intercept({ path: '/token', method: 'POST' })
      .reply(500, {});
    const verifier = new GoogleVerifier({
      serviceAccountEmail: 'sa@project.iam.gserviceaccount.com',
      privateKey: pem,
      packageName: 'com.holdclose.holdclose',
    });
    await expect(
      verifier.verifyGoogle('p', 'ptoken', 'production'),
    ).rejects.toBeInstanceOf(StoreUnavailableError);
  });
});

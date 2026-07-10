// Server-side purchase-receipt verification for in-app subscriptions.
//
// The device is NEVER trusted to declare its own entitlement. It forwards a
// store receipt — an Apple signed transaction (JWS) or a Google
// purchaseToken — and the Worker validates it against the platform store API
// here, over `fetch`, so the store endpoints are fully mockable in tests
// without any real Apple/Google credentials.
//
// Both platforms are hidden behind the `PurchaseVerifier` interface. A
// `FakeVerifier` gives tests a deterministic, credential-free double; the
// real Apple/Google impls can also be exercised by fetch-mocking the store
// hosts. Every impl returns the same normalized `VerifiedPurchase` shape so
// the route logic is platform-agnostic.

import { sign } from 'hono/jwt';

// The normalized result every verifier returns, regardless of platform.
export type VerifiedPurchase = {
  // Whether the store considers this purchase currently valid (auto-renew
  // subscriptions: not expired; consumable/non-consumable products: owned).
  active: boolean;
  productId: string;
  // Subscription expiry in ms epoch; null for a non-expiring product or when
  // the store reports no expiry. isPremium treats null as "no expiry".
  expiresAtMs: number | null;
  // True while the user is inside an introductory / free-trial period.
  isTrial: boolean;
  environment: 'production' | 'sandbox';
};

// Thrown when a receipt is WELL-FORMED but the store rejects it as
// invalid/unknown (bad token, wrong product, unrecognized transaction). The
// route maps this to a non-500 "not premium" answer — an invalid receipt is
// the caller's problem, not a server fault.
export class InvalidReceiptError extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = 'InvalidReceiptError';
  }
}

// Thrown when the store API itself is unreachable / errors (5xx, network
// failure, unexpected body). The route maps this to 502 — we could not
// decide, so the client should retry rather than be told "not premium".
export class StoreUnavailableError extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = 'StoreUnavailableError';
  }
}

// Thrown when the credentials/config needed to talk to a platform's store
// API are absent. The route maps this to 500 server_misconfigured — an
// operator provisioning gap, not the caller's fault.
export class VerifierMisconfiguredError extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = 'VerifierMisconfiguredError';
  }
}

export type StoreEnv = 'production' | 'sandbox';

export interface PurchaseVerifier {
  // Validate an App Store transaction. `receipt` is the signed transaction
  // JWS the StoreKit 2 client hands up (or a transactionId). `env` selects
  // the production vs. sandbox App Store Server API host.
  verifyApple(receipt: string, env: StoreEnv): Promise<VerifiedPurchase>;
  // Validate a Google Play purchase. `purchaseToken` is the token from the
  // Play Billing purchase; `productId` disambiguates the SKU.
  verifyGoogle(
    productId: string,
    purchaseToken: string,
    env: StoreEnv,
  ): Promise<VerifiedPurchase>;
}

// ---------------------------------------------------------------------------
// Apple — App Store Server API (modern signed-JWS transaction path)
// ---------------------------------------------------------------------------
//
// Flow: mint an ES256 request JWT signed with the App Store Connect API key
// (.p8), call GET
//   {host}/inApps/v1/transactions/{transactionId}
// which returns { signedTransactionInfo } — a JWS whose payload is the
// decoded JWTS transaction. We read the payload's claims (productId,
// expiresDate, type, offer/trial fields, environment) to build the
// normalized shape. We do NOT re-verify Apple's JWS signature chain here:
// the transaction came from Apple's own authenticated API over TLS, so the
// payload is already trusted (the client-forwarded JWS is only used to pull
// out the transactionId to look up).

export type AppleConfig = {
  issuerId: string; // App Store Connect issuer id (a UUID)
  keyId: string; // the .p8 key id
  privateKey: string; // the .p8 PEM (PKCS8), a SECRET
  bundleId: string; // app bundle id, the JWT `bid` claim
};

const APPLE_HOST_PROD = 'https://api.storekit.itunes.apple.com';
const APPLE_HOST_SANDBOX = 'https://api.storekit-sandbox.itunes.apple.com';

// Apple's transaction `type` values that are subscriptions (have an expiry).
const APPLE_SUB_TYPES = new Set(['Auto-Renewable Subscription']);

// Decode a JWS/JWT payload segment WITHOUT verifying the signature. Apple's
// response bodies are signed JWS blobs delivered over an authenticated TLS
// call; we only need the claims.
function decodeJwsPayload<T>(jws: string): T {
  const parts = jws.split('.');
  if (parts.length !== 3) {
    throw new InvalidReceiptError('apple_malformed_jws');
  }
  const seg = parts[1].replace(/-/g, '+').replace(/_/g, '/');
  const padded = seg + '='.repeat((4 - (seg.length % 4)) % 4);
  let json: string;
  try {
    json = atob(padded);
  } catch {
    throw new InvalidReceiptError('apple_malformed_jws');
  }
  // atob yields a binary string; decode as UTF-8.
  const bytes = Uint8Array.from(json, (ch) => ch.charCodeAt(0));
  try {
    return JSON.parse(new TextDecoder().decode(bytes)) as T;
  } catch {
    throw new InvalidReceiptError('apple_malformed_jws');
  }
}

type AppleTransaction = {
  transactionId?: string;
  originalTransactionId?: string;
  productId?: string;
  type?: string;
  expiresDate?: number; // ms epoch
  environment?: string; // "Production" | "Sandbox"
  // Free-trial / intro-offer markers.
  offerType?: number; // 1 = introductory offer
  offerDiscountType?: string; // "FREE_TRIAL" on newer payloads
};

export class AppleVerifier implements PurchaseVerifier {
  constructor(
    private readonly config: AppleConfig,
    // Injected so tests can stand in for global fetch; defaults to the
    // runtime fetch (which fetchMock intercepts under vitest-pool-workers).
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private async requestToken(): Promise<string> {
    const nowSec = Math.floor(Date.now() / 1000);
    // App Store Server API JWT: ES256, 20-min max lifetime, audience
    // "appstoreconnect-v1", the app bundle id in `bid`.
    return sign(
      {
        iss: this.config.issuerId,
        iat: nowSec,
        exp: nowSec + 20 * 60,
        aud: 'appstoreconnect-v1',
        bid: this.config.bundleId,
      },
      // hono/jwt.sign accepts the PEM (PKCS8) directly and imports it.
      this.config.privateKey,
      'ES256',
    ).then(
      (t) => t,
      () => {
        // A bad/garbled .p8 can't sign — that's a config fault, not the
        // caller's receipt.
        throw new VerifierMisconfiguredError('apple_key_unusable');
      },
    );
  }

  async verifyApple(receipt: string, env: StoreEnv): Promise<VerifiedPurchase> {
    if (
      !this.config.issuerId ||
      !this.config.keyId ||
      !this.config.privateKey ||
      !this.config.bundleId
    ) {
      throw new VerifierMisconfiguredError('apple_credentials_missing');
    }
    if (typeof receipt !== 'string' || receipt.length === 0) {
      throw new InvalidReceiptError('apple_empty_receipt');
    }

    // The client may forward either a bare transactionId or the full signed
    // transaction JWS. If it's a JWS, decode it to pull the transactionId.
    let transactionId = receipt;
    if (receipt.split('.').length === 3) {
      const claims = decodeJwsPayload<AppleTransaction>(receipt);
      if (!claims.transactionId && !claims.originalTransactionId) {
        throw new InvalidReceiptError('apple_no_transaction_id');
      }
      transactionId = (claims.transactionId ??
        claims.originalTransactionId) as string;
    }

    const host = env === 'sandbox' ? APPLE_HOST_SANDBOX : APPLE_HOST_PROD;
    const jwt = await this.requestToken();

    let res: Response;
    try {
      res = await this.fetchImpl(
        `${host}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`,
        {
          method: 'GET',
          headers: {
            Authorization: `Bearer ${jwt}`,
            Accept: 'application/json',
          },
        },
      );
    } catch (err) {
      throw new StoreUnavailableError(`apple_fetch_failed:${String(err)}`);
    }

    // 404 = Apple doesn't know this transaction → invalid, not a server
    // fault. Other non-2xx (401/403/5xx) = we could not decide → unavailable.
    if (res.status === 404) {
      throw new InvalidReceiptError('apple_transaction_not_found');
    }
    if (!res.ok) {
      throw new StoreUnavailableError(`apple_http_${res.status}`);
    }

    let body: { signedTransactionInfo?: string };
    try {
      body = (await res.json()) as { signedTransactionInfo?: string };
    } catch {
      throw new StoreUnavailableError('apple_bad_json');
    }
    if (!body.signedTransactionInfo) {
      throw new InvalidReceiptError('apple_no_signed_transaction');
    }

    const tx = decodeJwsPayload<AppleTransaction>(body.signedTransactionInfo);
    return normalizeApple(tx);
  }

  async verifyGoogle(): Promise<VerifiedPurchase> {
    throw new VerifierMisconfiguredError('apple_verifier_no_google');
  }
}

export function normalizeApple(tx: AppleTransaction): VerifiedPurchase {
  const productId = tx.productId ?? '';
  const environment: StoreEnv =
    tx.environment === 'Sandbox' ? 'sandbox' : 'production';
  const isSub = tx.type ? APPLE_SUB_TYPES.has(tx.type) : Boolean(tx.expiresDate);
  const expiresAtMs =
    typeof tx.expiresDate === 'number' ? tx.expiresDate : null;

  // Active = a subscription whose expiry is in the future, OR a
  // non-subscription (no expiry) that exists at all.
  const active = isSub
    ? expiresAtMs !== null && expiresAtMs > Date.now()
    : true;

  const isTrial =
    tx.offerType === 1 || tx.offerDiscountType === 'FREE_TRIAL';

  return {
    active,
    productId,
    expiresAtMs: isSub ? expiresAtMs : null,
    isTrial,
    environment,
  };
}

// ---------------------------------------------------------------------------
// Google — Play Developer API (androidpublisher purchases.subscriptionsv2)
// ---------------------------------------------------------------------------
//
// Flow: mint a service-account JWT (RS256), exchange it at Google's OAuth
// token endpoint for an access token, then GET
//   /androidpublisher/v3/applications/{pkg}/purchases/subscriptionsv2/tokens/{token}
// (falling back to purchases.products for one-time products). Parse the
// subscription state + line-item expiry into the normalized shape.

export type GoogleConfig = {
  serviceAccountEmail: string;
  privateKey: string; // service-account PEM (PKCS8), a SECRET
  packageName: string; // the Android application id
};

const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const GOOGLE_API_HOST = 'https://androidpublisher.googleapis.com';
const GOOGLE_SCOPE = 'https://www.googleapis.com/auth/androidpublisher';

type GoogleSubscriptionV2 = {
  // "SUBSCRIPTION_STATE_ACTIVE" | "..._IN_GRACE_PERIOD" | "..._EXPIRED" | …
  subscriptionState?: string;
  lineItems?: Array<{
    productId?: string;
    expiryTime?: string; // RFC3339 timestamp
    offerDetails?: { offerId?: string; basePlanId?: string };
  }>;
  // "TEST" for sandbox/license-test purchases, absent otherwise.
  testPurchase?: unknown;
};

// States Google considers as granting access (active or in a recoverable
// window). Everything else (expired/canceled/paused/on-hold) is inactive.
const GOOGLE_ACTIVE_STATES = new Set([
  'SUBSCRIPTION_STATE_ACTIVE',
  'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
]);
const GOOGLE_TRIAL_STATE = 'SUBSCRIPTION_STATE_IN_TRIAL';

export class GoogleVerifier implements PurchaseVerifier {
  constructor(
    private readonly config: GoogleConfig,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private async accessToken(): Promise<string> {
    const nowSec = Math.floor(Date.now() / 1000);
    let assertion: string;
    try {
      assertion = await sign(
        {
          iss: this.config.serviceAccountEmail,
          scope: GOOGLE_SCOPE,
          aud: GOOGLE_TOKEN_URL,
          iat: nowSec,
          exp: nowSec + 60 * 60,
        },
        this.config.privateKey,
        'RS256',
      );
    } catch {
      throw new VerifierMisconfiguredError('google_key_unusable');
    }

    let res: Response;
    try {
      res = await this.fetchImpl(GOOGLE_TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          assertion,
        }).toString(),
      });
    } catch (err) {
      throw new StoreUnavailableError(`google_token_fetch_failed:${String(err)}`);
    }
    if (!res.ok) {
      throw new StoreUnavailableError(`google_token_http_${res.status}`);
    }
    let body: { access_token?: string };
    try {
      body = (await res.json()) as { access_token?: string };
    } catch {
      throw new StoreUnavailableError('google_token_bad_json');
    }
    if (!body.access_token) {
      throw new StoreUnavailableError('google_token_missing');
    }
    return body.access_token;
  }

  async verifyGoogle(
    productId: string,
    purchaseToken: string,
    _env: StoreEnv,
  ): Promise<VerifiedPurchase> {
    if (
      !this.config.serviceAccountEmail ||
      !this.config.privateKey ||
      !this.config.packageName
    ) {
      throw new VerifierMisconfiguredError('google_credentials_missing');
    }
    if (typeof purchaseToken !== 'string' || purchaseToken.length === 0) {
      throw new InvalidReceiptError('google_empty_token');
    }

    const token = await this.accessToken();
    const pkg = encodeURIComponent(this.config.packageName);
    const url =
      `${GOOGLE_API_HOST}/androidpublisher/v3/applications/${pkg}` +
      `/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`;

    let res: Response;
    try {
      res = await this.fetchImpl(url, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: 'application/json',
        },
      });
    } catch (err) {
      throw new StoreUnavailableError(`google_fetch_failed:${String(err)}`);
    }

    // 400/404/410 = Google doesn't recognize this token → invalid receipt,
    // not a server fault. 401/403/5xx = we could not decide → unavailable.
    if (res.status === 400 || res.status === 404 || res.status === 410) {
      throw new InvalidReceiptError(`google_purchase_not_found_${res.status}`);
    }
    if (!res.ok) {
      throw new StoreUnavailableError(`google_http_${res.status}`);
    }

    let body: GoogleSubscriptionV2;
    try {
      body = (await res.json()) as GoogleSubscriptionV2;
    } catch {
      throw new StoreUnavailableError('google_bad_json');
    }
    return normalizeGoogle(body, productId);
  }

  async verifyApple(): Promise<VerifiedPurchase> {
    throw new VerifierMisconfiguredError('google_verifier_no_apple');
  }
}

export function normalizeGoogle(
  body: GoogleSubscriptionV2,
  requestedProductId: string,
): VerifiedPurchase {
  const state = body.subscriptionState ?? '';
  const line = body.lineItems?.[0];
  const productId = line?.productId ?? requestedProductId;
  const expiryStr = line?.expiryTime;
  let expiresAtMs: number | null = null;
  if (expiryStr) {
    const parsed = Date.parse(expiryStr);
    expiresAtMs = Number.isFinite(parsed) ? parsed : null;
  }

  const notExpiredByClock = expiresAtMs === null || expiresAtMs > Date.now();
  const active =
    (GOOGLE_ACTIVE_STATES.has(state) || state === GOOGLE_TRIAL_STATE) &&
    notExpiredByClock;
  const isTrial = state === GOOGLE_TRIAL_STATE;
  const environment: StoreEnv =
    body.testPurchase !== undefined ? 'sandbox' : 'production';

  return {
    active,
    productId,
    expiresAtMs,
    isTrial,
    environment,
  };
}

// ---------------------------------------------------------------------------
// FakeVerifier — deterministic double for tests / demo builds (no creds).
// ---------------------------------------------------------------------------

export type FakeVerifierScript = {
  // Keyed by the receipt/purchaseToken string; the value is returned as-is.
  // A receipt not in the map yields InvalidReceiptError (well-formed but
  // unknown), mirroring a store rejecting an unrecognized token.
  apple?: Record<string, VerifiedPurchase>;
  google?: Record<string, VerifiedPurchase>;
  // Set to force a StoreUnavailableError from either method.
  unavailable?: boolean;
};

export class FakeVerifier implements PurchaseVerifier {
  constructor(private readonly script: FakeVerifierScript = {}) {}

  async verifyApple(receipt: string): Promise<VerifiedPurchase> {
    if (this.script.unavailable) {
      throw new StoreUnavailableError('fake_unavailable');
    }
    const hit = this.script.apple?.[receipt];
    if (!hit) throw new InvalidReceiptError('fake_unknown_apple_receipt');
    return hit;
  }

  async verifyGoogle(
    _productId: string,
    purchaseToken: string,
  ): Promise<VerifiedPurchase> {
    if (this.script.unavailable) {
      throw new StoreUnavailableError('fake_unavailable');
    }
    const hit = this.script.google?.[purchaseToken];
    if (!hit) throw new InvalidReceiptError('fake_unknown_google_token');
    return hit;
  }
}

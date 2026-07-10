// In-app-purchase entitlement routes (JWT-gated, mounted under /api/v1).
//
//   POST /billing/verify      — verify a store receipt, upsert the caller's
//                               entitlement, return the derived state.
//   GET  /billing/entitlement — read the stored authoritative entitlement;
//                               this is the source of truth the app reads on
//                               launch (the device never decides its own).
//
// The store APIs are reached only through a `PurchaseVerifier` (see
// billing/verifier.ts). By default the route builds the real Apple/Google
// verifiers from the Worker's secrets/vars; a test injects a `FakeVerifier`
// (or fetch-mocks the store hosts) so the suite runs offline.

import { eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import { entitlements } from '../db/schema';
import {
  AppleVerifier,
  GoogleVerifier,
  InvalidReceiptError,
  StoreUnavailableError,
  VerifierMisconfiguredError,
  type PurchaseVerifier,
  type StoreEnv,
  type VerifiedPurchase,
} from '../billing/verifier';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

export type BillingBindings = AuthBindings & {
  FORUM_DB: D1Database;
  // --- Apple App Store Server API creds ---
  APPLE_ISSUER_ID?: string;
  APPLE_KEY_ID?: string;
  APPLE_PRIVATE_KEY?: string; // the .p8 PEM — a SECRET
  APPLE_BUNDLE_ID?: string;
  // --- Google Play Developer API creds ---
  GOOGLE_PLAY_SA_EMAIL?: string;
  GOOGLE_PLAY_SA_PRIVATE_KEY?: string; // service-account PEM — a SECRET
  GOOGLE_PLAY_PACKAGE?: string;
};

export type BillingVariables = AuthVariables;

type Platform = 'ios' | 'android';

// Build the platform verifiers from env. Returns undefined for a platform
// whose creds are absent so the route can answer 500 server_misconfigured
// only when that platform is actually requested.
function buildVerifiers(env: BillingBindings): {
  apple?: PurchaseVerifier;
  google?: PurchaseVerifier;
} {
  const out: { apple?: PurchaseVerifier; google?: PurchaseVerifier } = {};
  if (
    env.APPLE_ISSUER_ID &&
    env.APPLE_KEY_ID &&
    env.APPLE_PRIVATE_KEY &&
    env.APPLE_BUNDLE_ID
  ) {
    out.apple = new AppleVerifier({
      issuerId: env.APPLE_ISSUER_ID,
      keyId: env.APPLE_KEY_ID,
      privateKey: env.APPLE_PRIVATE_KEY,
      bundleId: env.APPLE_BUNDLE_ID,
    });
  }
  if (
    env.GOOGLE_PLAY_SA_EMAIL &&
    env.GOOGLE_PLAY_SA_PRIVATE_KEY &&
    env.GOOGLE_PLAY_PACKAGE
  ) {
    out.google = new GoogleVerifier({
      serviceAccountEmail: env.GOOGLE_PLAY_SA_EMAIL,
      privateKey: env.GOOGLE_PLAY_SA_PRIVATE_KEY,
      packageName: env.GOOGLE_PLAY_PACKAGE,
    });
  }
  return out;
}

// isPremium is derived, never stored: active AND (no expiry OR expiry in the
// future). Keeping it derived means a row that quietly ages past its expiry
// (no re-verify yet) still reads as not-premium.
function isPremium(status: string, expiresAtMs: number | null): boolean {
  if (status !== 'active' && status !== 'trial') return false;
  return expiresAtMs === null || expiresAtMs > Date.now();
}

// Map a verified store result to the persisted `status` enum.
function statusFor(v: VerifiedPurchase): 'active' | 'trial' | 'expired' {
  if (!v.active) return 'expired';
  return v.isTrial ? 'trial' : 'active';
}

function entitlementResponse(row: {
  status: string;
  expiresAt: number | null;
  productId: string;
  platform?: string;
}) {
  return {
    isPremium: isPremium(row.status, row.expiresAt),
    inTrial: row.status === 'trial' && isPremium(row.status, row.expiresAt),
    expiresAt: row.expiresAt,
    productId: row.productId,
    ...(row.platform ? { platform: row.platform } : {}),
  };
}

export const billingRouter = (
  // Injected in tests. Production passes undefined and the route builds the
  // real verifiers from env per request.
  injected?: { apple?: PurchaseVerifier; google?: PurchaseVerifier },
) => {
  const router = new Hono<{
    Bindings: BillingBindings;
    Variables: BillingVariables;
  }>();

  router.post('/verify', async (c) => {
    const userId = c.get('userId');
    const db = drizzle(c.env.FORUM_DB);

    // --- Parse + validate the body --------------------------------------
    let body: { platform?: unknown; productId?: unknown; receipt?: unknown };
    try {
      body = (await c.req.json()) as typeof body;
    } catch {
      return c.json({ error: 'bad_request' }, 400);
    }
    const platform = body.platform;
    const productId = body.productId;
    const receipt = body.receipt;
    if (
      (platform !== 'ios' && platform !== 'android') ||
      typeof productId !== 'string' ||
      productId.length === 0 ||
      typeof receipt !== 'string' ||
      receipt.length === 0
    ) {
      return c.json({ error: 'bad_request' }, 400);
    }
    const plat = platform as Platform;

    // Sandbox vs. production: the store env is server-derived, not client-
    // asserted. We attempt production first and let each verifier report the
    // environment it observed; an operator can also flip via APPLE/GOOGLE
    // env, but defaulting to production is the safe posture.
    const storeEnv: StoreEnv = 'production';

    const verifiers = injected ?? buildVerifiers(c.env);
    const verifier = plat === 'ios' ? verifiers.apple : verifiers.google;
    if (!verifier) {
      // The platform's creds are not provisioned on this Worker.
      return c.json({ error: 'server_misconfigured' }, 500);
    }

    // --- Verify against the store ---------------------------------------
    let verified: VerifiedPurchase;
    try {
      verified =
        plat === 'ios'
          ? await verifier.verifyApple(receipt, storeEnv)
          : await verifier.verifyGoogle(productId, receipt, storeEnv);
    } catch (err) {
      if (err instanceof VerifierMisconfiguredError) {
        return c.json({ error: 'server_misconfigured' }, 500);
      }
      if (err instanceof StoreUnavailableError) {
        // 502: the store API was unreachable — we could not decide.
        return c.json({ error: 'store_unavailable' }, 502);
      }
      if (err instanceof InvalidReceiptError) {
        // Well-formed but invalid receipt: NOT a 500. Persist a "none" row so
        // GET reflects the (lack of) entitlement, and answer 200 with
        // isPremium:false — the client wanted an answer, and it got one.
        const now = new Date();
        await db
          .insert(entitlements)
          .values({
            userId,
            platform: plat,
            productId,
            status: 'none',
            expiresAt: null,
            environment: 'production',
            latestReceipt: receipt,
            createdAt: now,
            updatedAt: now,
          })
          .onConflictDoUpdate({
            target: entitlements.userId,
            set: {
              platform: plat,
              productId,
              status: 'none',
              expiresAt: null,
              latestReceipt: receipt,
              updatedAt: now,
            },
          });
        return c.json(
          {
            isPremium: false,
            inTrial: false,
            expiresAt: null,
            productId,
            platform: plat,
          },
          200,
        );
      }
      throw err; // genuinely unexpected — let the app-level onError 500 it.
    }

    // --- UPSERT the authoritative entitlement row -----------------------
    const status = statusFor(verified);
    const now = new Date();
    await db
      .insert(entitlements)
      .values({
        userId,
        platform: plat,
        productId: verified.productId || productId,
        status,
        expiresAt: verified.expiresAtMs,
        environment: verified.environment,
        latestReceipt: receipt,
        createdAt: now,
        updatedAt: now,
      })
      .onConflictDoUpdate({
        target: entitlements.userId,
        set: {
          platform: plat,
          productId: verified.productId || productId,
          status,
          expiresAt: verified.expiresAtMs,
          environment: verified.environment,
          latestReceipt: receipt,
          updatedAt: now,
        },
      });

    return c.json(
      {
        isPremium: isPremium(status, verified.expiresAtMs),
        inTrial: status === 'trial' && isPremium(status, verified.expiresAtMs),
        expiresAt: verified.expiresAtMs,
        productId: verified.productId || productId,
        platform: plat,
      },
      200,
    );
  });

  router.get('/entitlement', async (c) => {
    const userId = c.get('userId');
    const db = drizzle(c.env.FORUM_DB);

    const [row] = await db
      .select()
      .from(entitlements)
      .where(eq(entitlements.userId, userId));

    if (!row) {
      // No purchase on file — the default free tier.
      return c.json(
        { isPremium: false, inTrial: false, expiresAt: null, productId: null },
        200,
      );
    }
    return c.json(entitlementResponse(row), 200);
  });

  return router;
};

// Exported for direct unit testing of the derivation without a DB round-trip.
export const _test = { isPremium, statusFor };

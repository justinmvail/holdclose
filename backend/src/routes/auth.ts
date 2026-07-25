import { eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';
import { sign } from 'hono/jwt';

import {
  GoogleTokenError,
  parseClientIds,
  verifyGoogleIdToken,
  type JwksFetcher,
} from '../auth/google';
import { profiles } from '../db/schema';

export type AuthRouteBindings = {
  FORUM_DB: D1Database;
  // Allowed Google OAuth audience(s). Single value = the Web client id; may
  // be a comma-separated list so a future iOS client id audience also passes.
  GOOGLE_CLIENT_ID: string;
  // HMAC key for the session JWTs this route MINTS after verifying the
  // Google ID token. The same secret backs `middleware/auth.ts`
  // verification — but it lives ONLY on the Worker. The client never
  // signs; it carries the opaque token returned here.
  FORUM_JWT_SECRET: string;
};

/// Lifetime of a minted session token. Long enough that an alpha tester
/// doesn't re-auth weekly; short enough that a leaked token ages out.
/// The client refreshes by re-running the silent Google exchange when
/// the backend answers 401 + `Token-Expired: true`.
export const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60;

// Deterministic 6-hex-char hash of the user id — the same default-name shape
// minted by the profiles bootstrap, reused here for parity.
async function defaultDisplayName(holdcloseUserId: string): Promise<string> {
  const bytes = new TextEncoder().encode(holdcloseUserId);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  const hex = Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return `Caregiver_${hex.slice(0, 6)}`;
}

// `jwksFetcher` is injectable for tests; production uses the live Google
// certs endpoint (the route's default when undefined).
export const authRouter = (jwksFetcher?: JwksFetcher) => {
  const router = new Hono<{ Bindings: AuthRouteBindings }>();

  router.post('/google', async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: 'missing_id_token' }, 400);
    }
    const idToken =
      body && typeof body === 'object'
        ? (body as { id_token?: unknown }).id_token
        : undefined;
    if (typeof idToken !== 'string' || idToken.length === 0) {
      return c.json({ error: 'missing_id_token' }, 400);
    }

    const clientIds = parseClientIds(c.env.GOOGLE_CLIENT_ID);
    if (clientIds.length === 0) {
      return c.json({ error: 'server_misconfigured' }, 500);
    }
    const sessionSecret = c.env.FORUM_JWT_SECRET;
    if (!sessionSecret) {
      return c.json({ error: 'server_misconfigured' }, 500);
    }

    let verified;
    try {
      verified = await verifyGoogleIdToken(idToken, { clientIds, jwksFetcher });
    } catch (err) {
      if (err instanceof GoogleTokenError) {
        return c.json({ error: 'invalid_token' }, 401);
      }
      // Anything else (JWKS fetch outage, crypto failure) is a server
      // fault, not the caller's token — propagate to the app-level
      // onError, which logs it and answers a GENERIC 500. Never echo
      // the error itself: it can quote request internals.
      throw err;
    }

    const userId = verified.sub;
    const db = drizzle(c.env.FORUM_DB);

    const [existing] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.holdcloseUserId, userId));

    let username: string | null;
    if (existing) {
      // Profile already provisioned — leave it untouched.
      username = existing.username ?? null;
    } else {
      const displayName =
        verified.name && verified.name.trim().length > 0
          ? verified.name
          : await defaultDisplayName(userId);
      const [created] = await db
        .insert(profiles)
        .values({ displayName, holdcloseUserId: userId })
        .returning();
      username = created.username ?? null;
    }

    // Mint the session JWT HERE, server-side, after the Google identity
    // is proven. This is the ONLY place session tokens come from — the
    // client carries the token opaquely and never holds the HMAC secret,
    // so possession of an app binary mints nothing.
    const iat = Math.floor(Date.now() / 1000);
    const exp = iat + SESSION_TTL_SECONDS;
    const token = await sign(
      { sub: userId, iat, exp },
      sessionSecret,
      'HS256',
    );

    return c.json(
      {
        user_id: userId,
        email: verified.email,
        name: verified.name,
        username,
        token,
        token_expires_at: exp,
      },
      200,
    );
  });

  return router;
};

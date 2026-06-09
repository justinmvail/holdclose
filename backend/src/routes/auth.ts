import { eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

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
};

// Deterministic 6-hex-char hash of the user id — the same default-name shape
// minted by the profiles bootstrap, reused here for parity.
async function defaultDisplayName(careblazersUserId: string): Promise<string> {
  const bytes = new TextEncoder().encode(careblazersUserId);
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

    let verified;
    try {
      verified = await verifyGoogleIdToken(idToken, { clientIds, jwksFetcher });
    } catch (err) {
      if (err instanceof GoogleTokenError) {
        return c.json({ error: 'invalid_token' }, 401);
      }
      throw err;
    }

    const userId = verified.sub;
    const db = drizzle(c.env.FORUM_DB);

    const [existing] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.careblazersUserId, userId));

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
        .values({ displayName, careblazersUserId: userId })
        .returning();
      username = created.username ?? null;
    }

    return c.json(
      {
        user_id: userId,
        email: verified.email,
        name: verified.name,
        username,
      },
      200,
    );
  });

  return router;
};

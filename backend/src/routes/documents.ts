import { and, eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono, type Context } from 'hono';

import { circleMembers, circles, profiles, type Profile } from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

export type DocumentsBindings = AuthBindings & {
  FORUM_DB: D1Database;
  DOC_BLOBS: R2Bucket;
};

export type DocumentsVariables = AuthVariables;

type Db = ReturnType<typeof drizzle>;

// Reject anything larger than this. Document scans are JPEGs of an ID card or
// a single page — a few MB is generous. Keeps a hostile client from filling R2.
const MAX_BLOB_BYTES = 8 * 1024 * 1024;

// R2 object keys are prefixed by circle so a circle can never address another
// circle's blobs, and the per-document key is constrained to a safe charset.
const KEY_PATTERN = /^[A-Za-z0-9._-]{1,200}$/;

async function loadProfileByUserId(
  db: Db,
  careblazersUserId: string,
): Promise<Profile | undefined> {
  const [row] = await db
    .select()
    .from(profiles)
    .where(eq(profiles.careblazersUserId, careblazersUserId));
  return row;
}

export const documentsRouter = () => {
  const router = new Hono<{
    Bindings: DocumentsBindings;
    Variables: DocumentsVariables;
  }>();

  // Mirror sync.ts authorize: caller must have a profile and be a member of
  // the target circle. Returns an error Response to short-circuit on failure.
  async function authorize(
    c: Context<{ Bindings: DocumentsBindings; Variables: DocumentsVariables }>,
    db: Db,
    circleId: string,
  ): Promise<{ ok: true; profile: Profile } | { ok: false; res: Response }> {
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return { ok: false, res: c.json({ error: 'profile_not_found' }, 404) };
    }
    const [circle] = await db
      .select({ id: circles.id })
      .from(circles)
      .where(eq(circles.id, circleId));
    if (!circle) {
      return { ok: false, res: c.json({ error: 'not_found' }, 404) };
    }
    const [membership] = await db
      .select()
      .from(circleMembers)
      .where(
        and(
          eq(circleMembers.circleId, circleId),
          eq(circleMembers.profileId, profile.id),
        ),
      );
    if (!membership) {
      return { ok: false, res: c.json({ error: 'forbidden' }, 403) };
    }
    return { ok: true, profile };
  }

  // Namespace every object under the circle so cross-circle reads are
  // structurally impossible even before the membership check.
  function storageKey(circleId: string, key: string): string {
    return `documents/${circleId}/${key}`;
  }

  // Upload a document scan blob. Body = raw image bytes. Returns the full
  // storage key the caller should persist on the document row.
  router.put('/blob/:circleId/:key', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const circleId = c.req.param('circleId');
    const key = c.req.param('key');
    if (!KEY_PATTERN.test(key)) {
      return c.json({ error: 'invalid_key' }, 400);
    }
    const authd = await authorize(c, db, circleId);
    if (!authd.ok) return authd.res;

    const body = await c.req.arrayBuffer();
    if (body.byteLength === 0) {
      return c.json({ error: 'empty_body' }, 400);
    }
    if (body.byteLength > MAX_BLOB_BYTES) {
      return c.json({ error: 'payload_too_large' }, 413);
    }

    const fullKey = storageKey(circleId, key);
    const contentType =
      c.req.header('Content-Type') || 'application/octet-stream';
    await c.env.DOC_BLOBS.put(fullKey, body, {
      httpMetadata: { contentType },
    });

    return c.json({ key: fullKey }, 200);
  });

  // Stream a document scan blob back. 404 if the object is absent.
  router.get('/blob/:circleId/:key', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const circleId = c.req.param('circleId');
    const key = c.req.param('key');
    if (!KEY_PATTERN.test(key)) {
      return c.json({ error: 'invalid_key' }, 400);
    }
    const authd = await authorize(c, db, circleId);
    if (!authd.ok) return authd.res;

    const obj = await c.env.DOC_BLOBS.get(storageKey(circleId, key));
    if (!obj) {
      return c.json({ error: 'not_found' }, 404);
    }

    const contentType =
      obj.httpMetadata?.contentType || 'application/octet-stream';
    return new Response(obj.body, {
      status: 200,
      headers: { 'Content-Type': contentType },
    });
  });

  return router;
};

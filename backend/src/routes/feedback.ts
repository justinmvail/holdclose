import { desc, eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import { feedback, profiles } from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

// In-app tester reports (the Report button) — server-side.
//
// Replaces the old pipe to `claude_shim.py` on the operator's laptop, which
// died silently when the backend moved to Cloudflare and the laptop's
// LaunchAgents + Funnel were disabled: builds kept baking the dead funnel URL,
// so reports went nowhere. This route takes the SAME JSON body the shim took
// (so the app's payload shape is unchanged), stores it in D1, and puts any
// screenshot in R2.
//
// Privacy posture — these carry PHI by nature (the message, the on-device log
// snapshot, and the screenshot can all show a loved one's care data):
//  * writes are JWT-gated (a report is always tied to a real account);
//  * reads are ADMIN-ONLY (the same `role = 'admin'` gate the moderation queue
//    uses) — a tester can file a report but can never read anyone else's;
//  * screenshots go to FORUM_MEDIA under `feedback/`, a prefix the PUBLIC
//    /media route deliberately refuses to serve (it only serves `avatars/`),
//    and are streamed back through this admin-gated route instead.
export type FeedbackBindings = AuthBindings & {
  FORUM_DB: D1Database;
  FORUM_MEDIA: R2Bucket;
};

export type FeedbackVariables = AuthVariables;

const ADMIN_ROLE = 'admin';

// Caps. A report is a sentence plus context, not a payload channel.
const MAX_MESSAGE_CHARS = 8_000;
const MAX_LOGS_CHARS = 200_000;
const MAX_FIELD_CHARS = 200; // route / tester_name / platform / versions
// Base64 of a phone screenshot: a full-res PNG runs ~1–2 MB → ~2.7 MB encoded.
const MAX_SCREENSHOT_B64_CHARS = 8 * 1024 * 1024;

const str = (v: unknown, max: number): string =>
  typeof v === 'string' ? v.slice(0, max) : '';

/** The app's `fb_<micros>` id. Constrained because it becomes an R2 key. */
const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

const screenshotKey = (id: string): string => `feedback/${id}.png`;

function decodeBase64(b64: string): Uint8Array | null {
  try {
    const binary = atob(b64);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

export function feedbackRouter() {
  const router = new Hono<{
    Bindings: FeedbackBindings;
    Variables: FeedbackVariables;
  }>();

  // File a report. Body is the app's FeedbackReport.toJson() plus an optional
  // `screenshot_base64` — byte-for-byte what it used to POST to the shim.
  router.post('/', async (c) => {
    const userId = c.get('userId');
    const db = drizzle(c.env.FORUM_DB);

    let raw: unknown;
    try {
      raw = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_body' }, 400);
    }
    if (!raw || typeof raw !== 'object') {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const body = raw as Record<string, unknown>;

    const id = str(body.id, 64);
    if (!ID_PATTERN.test(id)) {
      return c.json({ error: 'invalid_id' }, 400);
    }
    const message = str(body.message, MAX_MESSAGE_CHARS);
    if (message.trim().length === 0) {
      return c.json({ error: 'empty_message' }, 400);
    }

    // Screenshot (optional) → R2. Written BEFORE the row so a row never
    // advertises a `screenshot_key` that isn't there.
    let storedKey: string | null = null;
    const shot = body.screenshot_base64;
    if (typeof shot === 'string' && shot.length > 0) {
      if (shot.length > MAX_SCREENSHOT_B64_CHARS) {
        return c.json({ error: 'payload_too_large' }, 413);
      }
      const bytes = decodeBase64(shot);
      if (!bytes) {
        return c.json({ error: 'invalid_screenshot' }, 400);
      }
      storedKey = screenshotKey(id);
      await c.env.FORUM_MEDIA.put(storedKey, bytes, {
        httpMetadata: { contentType: 'image/png' },
      });
    }

    const createdAtRaw = str(body.created_at, 64);
    const parsed = createdAtRaw ? Date.parse(createdAtRaw) : Number.NaN;
    const createdAt = Number.isFinite(parsed) ? new Date(parsed) : new Date();

    const row = {
      id,
      userId,
      createdAt,
      category: str(body.category, 32) || 'bug',
      message,
      route: str(body.route, MAX_FIELD_CHARS),
      testerName: str(body.tester_name, MAX_FIELD_CHARS),
      platform: str(body.platform, MAX_FIELD_CHARS),
      osVersion: str(body.os_version, MAX_FIELD_CHARS),
      demoMode: body.demo_mode === true,
      appVersion: str(body.app_version, MAX_FIELD_CHARS),
      buildStamp: str(body.build_stamp, MAX_FIELD_CHARS),
      logs: str(body.logs, MAX_LOGS_CHARS),
      screenshotKey: storedKey,
    };

    // Idempotent on the app-minted id: the phone keeps a DURABLE OUTBOX and
    // re-sends anything it didn't get a 200 for, so a dropped response must
    // not produce a duplicate report on the retry.
    await db
      .insert(feedback)
      .values(row)
      .onConflictDoUpdate({ target: feedback.id, set: row });

    return c.json({ id, screenshot: storedKey !== null }, 200);
  });

  // --- Operator triage (admin only) ------------------------------------
  //
  // A tester can FILE a report but must never READ one: reports carry other
  // caregivers' PHI (message, logs, screenshot). Same `role = 'admin'` gate as
  // the moderation queue.
  async function requireAdmin(
    db: ReturnType<typeof drizzle>,
    careblazersUserId: string,
  ): Promise<boolean> {
    const [profile] = await db
      .select({ role: profiles.role })
      .from(profiles)
      .where(eq(profiles.careblazersUserId, careblazersUserId));
    return profile?.role === ADMIN_ROLE;
  }

  router.get('/', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    if (!(await requireAdmin(db, c.get('userId')))) {
      return c.json({ error: 'forbidden' }, 403);
    }

    const limitRaw = Number.parseInt(c.req.query('limit') ?? '50', 10);
    const limit = Number.isFinite(limitRaw)
      ? Math.min(Math.max(limitRaw, 1), 200)
      : 50;

    const rows = await db
      .select()
      .from(feedback)
      .orderBy(desc(feedback.createdAt))
      .limit(limit);

    return c.json({
      feedback: rows.map((r) => ({
        id: r.id,
        user_id: r.userId,
        created_at: r.createdAt.toISOString(),
        category: r.category,
        message: r.message,
        route: r.route,
        tester_name: r.testerName,
        platform: r.platform,
        os_version: r.osVersion,
        demo_mode: r.demoMode,
        app_version: r.appVersion,
        build_stamp: r.buildStamp,
        logs: r.logs,
        has_screenshot: r.screenshotKey !== null,
      })),
    });
  });

  // The screenshot, admin-gated. NOT reachable through the public /media
  // route — that one only serves `avatars/`.
  router.get('/:id/screenshot', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    if (!(await requireAdmin(db, c.get('userId')))) {
      return c.json({ error: 'forbidden' }, 403);
    }

    const id = c.req.param('id');
    if (!ID_PATTERN.test(id)) {
      return c.json({ error: 'not_found' }, 404);
    }
    const object = await c.env.FORUM_MEDIA.get(screenshotKey(id));
    if (!object) {
      return c.json({ error: 'not_found' }, 404);
    }
    return new Response(object.body, {
      headers: {
        'Content-Type': 'image/png',
        'Cache-Control': 'private, no-store',
        'X-Content-Type-Options': 'nosniff',
      },
    });
  });

  return router;
}

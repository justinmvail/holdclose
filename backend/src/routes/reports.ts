import { desc, eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import {
  comments,
  posts,
  profiles,
  REPORT_STATUS_ACTIONED,
  REPORT_STATUS_PENDING,
  REPORT_STATUS_REVIEWED,
  reports,
  type Profile,
  type Report,
} from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

export type ReportsBindings = AuthBindings & {
  FORUM_DB: D1Database;
};

export type ReportsVariables = AuthVariables;

const REASON_MIN = 1;
const REASON_MAX = 500;
const ADMIN_ROLE = 'admin';
const BANNED_ROLE = 'banned';

const TARGET_KIND_POST = 'post';
const TARGET_KIND_COMMENT = 'comment';

const ACTION_NO_ACTION = 'no_action';
const ACTION_HIDE_TARGET = 'hide_target';
const ACTION_BAN_USER = 'ban_user';

type TargetKind = typeof TARGET_KIND_POST | typeof TARGET_KIND_COMMENT;
type ReviewAction =
  | typeof ACTION_NO_ACTION
  | typeof ACTION_HIDE_TARGET
  | typeof ACTION_BAN_USER;

const isValidTargetKind = (k: unknown): k is TargetKind =>
  k === TARGET_KIND_POST || k === TARGET_KIND_COMMENT;

const isValidAction = (a: unknown): a is ReviewAction =>
  a === ACTION_NO_ACTION ||
  a === ACTION_HIDE_TARGET ||
  a === ACTION_BAN_USER;

type Db = ReturnType<typeof drizzle>;

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

function reportResponse(r: Report) {
  return {
    id: r.id,
    target_kind: r.targetKind,
    target_id: r.targetId,
    reporter_id: r.reporterId,
    reason: r.reason,
    status: r.status,
    created_at: r.createdAt.toISOString(),
    resolved_at: r.resolvedAt ? r.resolvedAt.toISOString() : null,
  };
}

// Resolves a target row to its author profile id. Returns undefined
// if the target was already gone (race: target hard-deleted before
// the admin processed the report) so the caller can still mark the
// report resolved without crashing.
async function targetAuthorId(
  db: Db,
  kind: TargetKind,
  id: string,
): Promise<string | undefined> {
  if (kind === TARGET_KIND_POST) {
    const [row] = await db.select().from(posts).where(eq(posts.id, id));
    return row?.authorId;
  }
  const [row] = await db.select().from(comments).where(eq(comments.id, id));
  return row?.authorId;
}

export const reportsRouter = () => {
  const router = new Hono<{
    Bindings: ReportsBindings;
    Variables: ReportsVariables;
  }>();

  // ---------- POST /api/v1/reports ----------
  // Any authed user with a profile can file a report. We don't
  // dedupe — a second report from the same user against the same
  // target lands as a fresh row, because the admin queue uses
  // volume of reports as a triage signal.

  router.post('/', async (c) => {
    const db = drizzle(c.env.FORUM_DB);

    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    let raw: unknown;
    try {
      raw = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_body' }, 400);
    }
    if (!raw || typeof raw !== 'object') {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const { target_kind, target_id, reason } = raw as {
      target_kind?: unknown;
      target_id?: unknown;
      reason?: unknown;
    };

    if (!isValidTargetKind(target_kind)) {
      return c.json({ error: 'invalid_target_kind' }, 400);
    }
    if (typeof target_id !== 'string' || target_id.length === 0) {
      return c.json({ error: 'invalid_target_id' }, 400);
    }
    if (
      typeof reason !== 'string' ||
      reason.length < REASON_MIN ||
      reason.length > REASON_MAX
    ) {
      return c.json({ error: 'invalid_reason' }, 400);
    }

    // Validate target exists. Hidden targets are still reportable —
    // a report against an already-hidden item is useful evidence
    // when deciding whether to escalate to a ban.
    if (target_kind === TARGET_KIND_POST) {
      const [row] = await db.select().from(posts).where(eq(posts.id, target_id));
      if (!row) {
        return c.json({ error: 'target_not_found' }, 404);
      }
    } else {
      const [row] = await db
        .select()
        .from(comments)
        .where(eq(comments.id, target_id));
      if (!row) {
        return c.json({ error: 'target_not_found' }, 404);
      }
    }

    const [created] = await db
      .insert(reports)
      .values({
        targetKind: target_kind,
        targetId: target_id,
        reporterId: profile.id,
        reason,
        status: REPORT_STATUS_PENDING,
      })
      .returning();
    return c.json(reportResponse(created), 201);
  });

  // ---------- GET /api/v1/reports?status=pending ----------
  // Admin only. Default status filter is `pending`; explicit
  // ?status=reviewed and ?status=actioned are also accepted so an
  // operator can audit history without raw SQL.

  router.get('/', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }
    if (profile.role !== ADMIN_ROLE) {
      return c.json({ error: 'forbidden' }, 403);
    }

    const statusParam = c.req.query('status') ?? REPORT_STATUS_PENDING;
    if (
      statusParam !== REPORT_STATUS_PENDING &&
      statusParam !== REPORT_STATUS_REVIEWED &&
      statusParam !== REPORT_STATUS_ACTIONED
    ) {
      return c.json({ error: 'invalid_status' }, 400);
    }

    const rows = await db
      .select()
      .from(reports)
      .where(eq(reports.status, statusParam))
      .orderBy(desc(reports.createdAt));

    return c.json({ reports: rows.map(reportResponse) }, 200);
  });

  // ---------- PATCH /api/v1/reports/:id ----------
  // Admin only. Body: { action: 'no_action' | 'hide_target' | 'ban_user' }.
  //   - no_action   → status: reviewed, no side effects.
  //   - hide_target → status: actioned, target row.hidden = true.
  //   - ban_user    → status: actioned, target row.hidden = true AND
  //                   target author's profile role = 'banned'.
  // Already-resolved reports return 409 to avoid double-actioning.

  router.patch('/:id', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }
    if (profile.role !== ADMIN_ROLE) {
      return c.json({ error: 'forbidden' }, 403);
    }

    const id = c.req.param('id');
    const [existing] = await db
      .select()
      .from(reports)
      .where(eq(reports.id, id));
    if (!existing) {
      return c.json({ error: 'report_not_found' }, 404);
    }
    if (existing.status !== REPORT_STATUS_PENDING) {
      return c.json({ error: 'report_already_resolved' }, 409);
    }

    let raw: unknown;
    try {
      raw = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_body' }, 400);
    }
    if (!raw || typeof raw !== 'object') {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const { action } = raw as { action?: unknown };
    if (!isValidAction(action)) {
      return c.json({ error: 'invalid_action' }, 400);
    }

    const now = new Date();
    const newStatus =
      action === ACTION_NO_ACTION
        ? REPORT_STATUS_REVIEWED
        : REPORT_STATUS_ACTIONED;

    // Hide the target for hide_target + ban_user. Look up the author
    // first so a target hard-deleted between report and review still
    // resolves cleanly (just the report row updates).
    let bannedAuthorId: string | undefined;
    if (action === ACTION_HIDE_TARGET || action === ACTION_BAN_USER) {
      const authorId = await targetAuthorId(
        db,
        existing.targetKind as TargetKind,
        existing.targetId,
      );
      if (existing.targetKind === TARGET_KIND_POST) {
        await db
          .update(posts)
          .set({ hidden: true, updatedAt: now })
          .where(eq(posts.id, existing.targetId));
      } else {
        await db
          .update(comments)
          .set({ hidden: true })
          .where(eq(comments.id, existing.targetId));
      }
      if (action === ACTION_BAN_USER && authorId) {
        bannedAuthorId = authorId;
        await db
          .update(profiles)
          .set({ role: BANNED_ROLE })
          .where(eq(profiles.id, authorId));
      }
    }

    const [updated] = await db
      .update(reports)
      .set({ status: newStatus, resolvedAt: now })
      .where(eq(reports.id, existing.id))
      .returning();

    return c.json(
      {
        ...reportResponse(updated),
        action,
        banned_user_id: bannedAuthorId ?? null,
      },
      200,
    );
  });

  return router;
};

// Re-export the action enum so tests + the Flutter client can stay
// in sync with the canonical values.
export const REPORT_ACTIONS = {
  NO_ACTION: ACTION_NO_ACTION,
  HIDE_TARGET: ACTION_HIDE_TARGET,
  BAN_USER: ACTION_BAN_USER,
} as const;

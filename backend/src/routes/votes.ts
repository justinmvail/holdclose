import { and, eq, sql } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import {
  comments,
  posts,
  profiles,
  VOTE_TARGET_COMMENT,
  VOTE_TARGET_POST,
  votes,
  type Comment,
  type Post,
  type Profile,
} from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

export type VotesBindings = AuthBindings & {
  FORUM_DB: D1Database;
};

export type VotesVariables = AuthVariables;

type Db = ReturnType<typeof drizzle>;

type TargetKind = typeof VOTE_TARGET_POST | typeof VOTE_TARGET_COMMENT;

type VoteValue = -1 | 0 | 1;

const isValidTargetKind = (k: unknown): k is TargetKind =>
  k === VOTE_TARGET_POST || k === VOTE_TARGET_COMMENT;

const isValidValue = (v: unknown): v is VoteValue =>
  v === -1 || v === 0 || v === 1;

async function loadProfileByUserId(
  db: Db,
  holdcloseUserId: string,
): Promise<Profile | undefined> {
  const [row] = await db
    .select()
    .from(profiles)
    .where(eq(profiles.holdcloseUserId, holdcloseUserId));
  return row;
}

type VisibleTarget =
  | { kind: typeof VOTE_TARGET_POST; row: Post }
  | { kind: typeof VOTE_TARGET_COMMENT; row: Comment };

async function loadVisibleTarget(
  db: Db,
  kind: TargetKind,
  id: string,
): Promise<VisibleTarget | undefined> {
  if (kind === VOTE_TARGET_POST) {
    const [row] = await db.select().from(posts).where(eq(posts.id, id));
    if (!row || row.hidden) return undefined;
    return { kind: VOTE_TARGET_POST, row };
  }
  const [row] = await db.select().from(comments).where(eq(comments.id, id));
  if (!row || row.hidden) return undefined;
  return { kind: VOTE_TARGET_COMMENT, row };
}

export const votesRouter = () => {
  const router = new Hono<{
    Bindings: VotesBindings;
    Variables: VotesVariables;
  }>();

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
    const { target_kind, target_id, value } = raw as {
      target_kind?: unknown;
      target_id?: unknown;
      value?: unknown;
    };

    if (!isValidTargetKind(target_kind)) {
      return c.json({ error: 'invalid_target_kind' }, 400);
    }
    if (typeof target_id !== 'string' || target_id.length === 0) {
      return c.json({ error: 'invalid_target_id' }, 400);
    }
    if (!isValidValue(value)) {
      return c.json({ error: 'invalid_value' }, 400);
    }

    const target = await loadVisibleTarget(db, target_kind, target_id);
    if (!target) {
      return c.json({ error: 'target_not_found' }, 404);
    }

    const [existing] = await db
      .select()
      .from(votes)
      .where(
        and(
          eq(votes.voterId, profile.id),
          eq(votes.targetKind, target_kind),
          eq(votes.targetId, target_id),
        ),
      );

    const currentValue: VoteValue = (existing?.value as VoteValue | undefined) ?? 0;
    if (value === currentValue) {
      // No write needed — same vote (including the 0/0 "withdraw a
      // vote you never cast" case). Return the count as-is.
      return c.json({ vote_count: target.row.voteCount, value: currentValue }, 200);
    }

    const delta = value - currentValue;

    // D1 batch is atomic: the vote row mutation and the counter
    // delta land together or not at all, so we can't drift between
    // the votes table and the cached vote_count even under
    // interleaved writes.
    if (target.kind === VOTE_TARGET_POST) {
      const voteOp =
        value === 0
          ? db.delete(votes).where(eq(votes.id, existing!.id))
          : existing
            ? db.update(votes).set({ value }).where(eq(votes.id, existing.id))
            : db.insert(votes).values({
                voterId: profile.id,
                targetKind: target_kind,
                targetId: target_id,
                value,
              });
      const counterOp = db
        .update(posts)
        .set({ voteCount: sql`${posts.voteCount} + ${delta}` })
        .where(eq(posts.id, target_id))
        .returning({ voteCount: posts.voteCount });

      const results = await db.batch([voteOp, counterOp]);
      const [counterRow] = results[1] as { voteCount: number }[];
      return c.json({ vote_count: counterRow.voteCount, value }, 200);
    }

    const voteOp =
      value === 0
        ? db.delete(votes).where(eq(votes.id, existing!.id))
        : existing
          ? db.update(votes).set({ value }).where(eq(votes.id, existing.id))
          : db.insert(votes).values({
              voterId: profile.id,
              targetKind: target_kind,
              targetId: target_id,
              value,
            });
    const counterOp = db
      .update(comments)
      .set({ voteCount: sql`${comments.voteCount} + ${delta}` })
      .where(eq(comments.id, target_id))
      .returning({ voteCount: comments.voteCount });

    const results = await db.batch([voteOp, counterOp]);
    const [counterRow] = results[1] as { voteCount: number }[];
    return c.json({ vote_count: counterRow.voteCount, value }, 200);
  });

  return router;
};

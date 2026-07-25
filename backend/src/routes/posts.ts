import { and, count, desc, eq, inArray, lt, or } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import {
  comments,
  posts,
  profiles,
  type Post,
  type Profile,
} from '../db/schema';
import { auth, type AuthBindings, type AuthVariables } from '../middleware/auth';
import { detectCrisisContent } from '../middleware/crisisFlag';

export type PostsBindings = AuthBindings & {
  FORUM_DB: D1Database;
};

export type PostsVariables = AuthVariables;

const DEFAULT_LIMIT = 25;
const MAX_LIMIT = 50;
const TITLE_MIN = 1;
const TITLE_MAX = 200;
const BODY_MIN = 1;
const BODY_MAX = 10000;
const ADMIN_ROLE = 'admin';

// Working window for the hot sort. The classic Reddit hot score
// depends on every visible post's vote/age, and SQLite-on-D1 has no
// LOG10 we can lean on, so we materialize a recent slice and rank
// it in JS instead of pushing logarithms into SQL. 500 is well
// above any practical first-page draw for v1 traffic.
const HOT_WINDOW_LIMIT = 500;

// Reddit's published epoch for the classic hot algorithm. Pins the
// time component to a stable, well-known scale.
const REDDIT_EPOCH_SECONDS = 1134028003;

// Reddit's published time-decay constant — 12.5 hours of free
// promotion before age starts to bite.
const HOT_DECAY_SECONDS = 45000;

type SortKey = 'hot' | 'new' | 'top';

const isValidSort = (s: string): s is SortKey =>
  s === 'hot' || s === 'new' || s === 'top';

function hotScore(voteCount: number, createdAt: Date): number {
  const order = Math.log10(Math.max(Math.abs(voteCount), 1));
  const sign = voteCount > 0 ? 1 : voteCount < 0 ? -1 : 0;
  const secondsSinceEpoch =
    createdAt.getTime() / 1000 - REDDIT_EPOCH_SECONDS;
  return sign * order + secondsSinceEpoch / HOT_DECAY_SECONDS;
}

// The author's public name fields, denormalized onto each post/comment
// response so the app can render the real @username (or display_name)
// without a second round-trip per author. `author` may be undefined for
// a row whose profile was deleted; both fields then fall to null.
//
// `commentCount` is the post's visible-comment tally, computed by the
// read routes from the comments table (there is no denormalized column,
// unlike vote_count). Write paths that don't compute it — create, patch
// — fall back to 0, the correct value for a just-created post and a
// harmless default for the others (the feed re-fetches the real count).
function postResponse(
  p: Post,
  author?: Pick<Profile, 'username' | 'displayName' | 'avatarUrl'>,
  commentCount = 0,
) {
  return {
    id: p.id,
    author_id: p.authorId,
    author_username: author?.username ?? null,
    author_display_name: author?.displayName ?? null,
    author_avatar_url: author?.avatarUrl ?? null,
    title: p.title,
    body: p.body,
    created_at: p.createdAt.toISOString(),
    updated_at: p.updatedAt.toISOString(),
    vote_count: p.voteCount,
    comment_count: commentCount,
    hidden: p.hidden,
    // crisis_flagged is deliberately NOT exposed (2026-06-11): the
    // watchdog's keyword triage (suicidality / self-harm / abuse,
    // recall-over-precision) stays between the author, the moderators,
    // and the watchdog — broadcasting it on anonymous reads published a
    // vulnerable caregiver's worst moment to every reader and scraper.
    // The author's supportive-resources banner is driven by the
    // `crisis_resources` field on the CREATE response instead.
  };
}

type Db = ReturnType<typeof drizzle>;

// Build a profileId -> {username, displayName} lookup for a batch of
// posts so the list endpoints can attach author names with a single
// extra query rather than one per row.
async function loadAuthors(
  db: Db,
  authorIds: string[],
): Promise<Map<string, Pick<Profile, 'username' | 'displayName' | 'avatarUrl'>>> {
  const map = new Map<string, Pick<Profile, 'username' | 'displayName' | 'avatarUrl'>>();
  const unique = [...new Set(authorIds)];
  if (unique.length === 0) {
    return map;
  }
  const rows = await db
    .select({
      id: profiles.id,
      username: profiles.username,
      displayName: profiles.displayName,
      avatarUrl: profiles.avatarUrl,
    })
    .from(profiles)
    .where(inArray(profiles.id, unique));
  for (const row of rows) {
    map.set(row.id, {
      username: row.username,
      displayName: row.displayName,
      avatarUrl: row.avatarUrl,
    });
  }
  return map;
}

// Build a postId -> comment count map for a batch of posts in one
// grouped query, so the feed attaches each post's reply tally without a
// per-post round-trip. Mirrors loadAuthors' batched shape. Tombstoned
// (hidden) comments are counted too: they stay in the thread as
// "[removed]" placeholders, so the feed's count matches the rows a
// reader actually sees. Posts with no comments are simply absent from
// the map; callers default those to 0.
async function loadCommentCounts(
  db: Db,
  postIds: string[],
): Promise<Map<string, number>> {
  const map = new Map<string, number>();
  const unique = [...new Set(postIds)];
  if (unique.length === 0) {
    return map;
  }
  const rows = await db
    .select({ postId: comments.postId, count: count() })
    .from(comments)
    .where(inArray(comments.postId, unique))
    .groupBy(comments.postId);
  for (const row of rows) {
    map.set(row.postId, row.count);
  }
  return map;
}

// The single-post comment tally for the detail route. Same counting
// rule as loadCommentCounts (hidden rows included).
async function loadCommentCount(db: Db, postId: string): Promise<number> {
  const [row] = await db
    .select({ count: count() })
    .from(comments)
    .where(eq(comments.postId, postId));
  return row?.count ?? 0;
}

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

async function loadVisiblePost(
  db: Db,
  id: string,
): Promise<Post | undefined> {
  const [row] = await db.select().from(posts).where(eq(posts.id, id));
  if (!row || row.hidden) {
    return undefined;
  }
  return row;
}

export const postsRouter = () => {
  const router = new Hono<{
    Bindings: PostsBindings;
    Variables: PostsVariables;
  }>();

  // ---------- Public reads ----------

  router.get('/', async (c) => {
    const db = drizzle(c.env.FORUM_DB);

    const sortParam = c.req.query('sort') ?? 'hot';
    if (!isValidSort(sortParam)) {
      return c.json({ error: 'invalid_sort' }, 400);
    }
    const sort = sortParam;

    const limitParam = c.req.query('limit');
    let limit = DEFAULT_LIMIT;
    if (limitParam !== undefined) {
      const parsed = Number.parseInt(limitParam, 10);
      if (Number.isNaN(parsed) || parsed <= 0) {
        return c.json({ error: 'invalid_limit' }, 400);
      }
      limit = Math.min(parsed, MAX_LIMIT);
    }

    const beforeId = c.req.query('before');
    let cursor: Post | undefined;
    if (beforeId !== undefined) {
      const [row] = await db
        .select()
        .from(posts)
        .where(eq(posts.id, beforeId));
      if (!row) {
        return c.json({ error: 'invalid_cursor' }, 400);
      }
      cursor = row;
    }

    if (sort === 'new') {
      const rows = await db
        .select()
        .from(posts)
        .where(
          cursor
            ? and(
                eq(posts.hidden, false),
                or(
                  lt(posts.createdAt, cursor.createdAt),
                  and(
                    eq(posts.createdAt, cursor.createdAt),
                    lt(posts.id, cursor.id),
                  ),
                ),
              )
            : eq(posts.hidden, false),
        )
        .orderBy(desc(posts.createdAt), desc(posts.id))
        .limit(limit);
      const authors = await loadAuthors(db, rows.map((r) => r.authorId));
      const counts = await loadCommentCounts(db, rows.map((r) => r.id));
      return c.json(
        {
          posts: rows.map((r) =>
            postResponse(r, authors.get(r.authorId), counts.get(r.id) ?? 0),
          ),
        },
        200,
      );
    }

    if (sort === 'top') {
      const rows = await db
        .select()
        .from(posts)
        .where(
          cursor
            ? and(
                eq(posts.hidden, false),
                or(
                  lt(posts.voteCount, cursor.voteCount),
                  and(
                    eq(posts.voteCount, cursor.voteCount),
                    lt(posts.id, cursor.id),
                  ),
                ),
              )
            : eq(posts.hidden, false),
        )
        .orderBy(desc(posts.voteCount), desc(posts.id))
        .limit(limit);
      const authors = await loadAuthors(db, rows.map((r) => r.authorId));
      const counts = await loadCommentCounts(db, rows.map((r) => r.id));
      return c.json(
        {
          posts: rows.map((r) =>
            postResponse(r, authors.get(r.authorId), counts.get(r.id) ?? 0),
          ),
        },
        200,
      );
    }

    // hot
    const candidates = await db
      .select()
      .from(posts)
      .where(eq(posts.hidden, false))
      .orderBy(desc(posts.createdAt))
      .limit(HOT_WINDOW_LIMIT);

    const scored = candidates
      .map((p) => ({ p, score: hotScore(p.voteCount, p.createdAt) }))
      .sort((a, b) => {
        if (b.score !== a.score) {
          return b.score - a.score;
        }
        // Stable tiebreak so a fixed dataset always paginates the
        // same way.
        return a.p.id < b.p.id ? 1 : -1;
      });

    let start = 0;
    if (cursor) {
      const idx = scored.findIndex((s) => s.p.id === cursor.id);
      start = idx >= 0 ? idx + 1 : scored.length;
    }
    const pageRows = scored.slice(start, start + limit).map((s) => s.p);
    const authors = await loadAuthors(db, pageRows.map((p) => p.authorId));
    const counts = await loadCommentCounts(db, pageRows.map((p) => p.id));
    const page = pageRows.map((p) =>
      postResponse(p, authors.get(p.authorId), counts.get(p.id) ?? 0),
    );
    return c.json({ posts: page }, 200);
  });

  router.get('/:id', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const post = await loadVisiblePost(db, c.req.param('id'));
    if (!post) {
      return c.json({ error: 'post_not_found' }, 404);
    }
    const authors = await loadAuthors(db, [post.authorId]);
    const commentCount = await loadCommentCount(db, post.id);
    return c.json(
      postResponse(post, authors.get(post.authorId), commentCount),
      200,
    );
  });

  // ---------- Authed writes ----------

  router.post('/', auth(), async (c) => {
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
    const { title, body } = raw as { title?: unknown; body?: unknown };
    if (
      typeof title !== 'string' ||
      title.length < TITLE_MIN ||
      title.length > TITLE_MAX
    ) {
      return c.json({ error: 'invalid_title' }, 400);
    }
    if (
      typeof body !== 'string' ||
      body.length < BODY_MIN ||
      body.length > BODY_MAX
    ) {
      return c.json({ error: 'invalid_body_text' }, 400);
    }

    const detection = detectCrisisContent(title, body);

    const [created] = await db
      .insert(posts)
      .values({
        authorId: profile.id,
        title,
        body,
        crisisFlagged: detection.flagged,
      })
      .returning();
    const payload: Record<string, unknown> = postResponse(created, profile);
    if (detection.flagged) {
      payload.crisis_resources = detection.resources;
    }
    return c.json(payload, 201);
  });

  router.patch('/:id', auth(), async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    const existing = await loadVisiblePost(db, c.req.param('id'));
    if (!existing) {
      return c.json({ error: 'post_not_found' }, 404);
    }
    if (existing.authorId !== profile.id) {
      return c.json({ error: 'forbidden' }, 403);
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
    const patch = raw as { body?: unknown };
    if (
      typeof patch.body !== 'string' ||
      patch.body.length < BODY_MIN ||
      patch.body.length > BODY_MAX
    ) {
      return c.json({ error: 'invalid_body_text' }, 400);
    }

    const [updated] = await db
      .update(posts)
      .set({ body: patch.body, updatedAt: new Date() })
      .where(eq(posts.id, existing.id))
      .returning();
    return c.json(postResponse(updated, profile), 200);
  });

  router.delete('/:id', auth(), async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    const existing = await loadVisiblePost(db, c.req.param('id'));
    if (!existing) {
      return c.json({ error: 'post_not_found' }, 404);
    }
    if (
      existing.authorId !== profile.id &&
      profile.role !== ADMIN_ROLE
    ) {
      return c.json({ error: 'forbidden' }, 403);
    }

    await db
      .update(posts)
      .set({ hidden: true, updatedAt: new Date() })
      .where(eq(posts.id, existing.id));
    return c.json({ id: existing.id, hidden: true }, 200);
  });

  return router;
};

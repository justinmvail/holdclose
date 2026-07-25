import { asc, count, desc, eq, inArray } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import {
  comments,
  MAX_COMMENT_DEPTH,
  posts,
  profiles,
  type Comment,
  type Post,
  type Profile,
} from '../db/schema';
import { auth, type AuthBindings, type AuthVariables } from '../middleware/auth';
import { detectCrisisContent } from '../middleware/crisisFlag';

export type CommentsBindings = AuthBindings & {
  FORUM_DB: D1Database;
};

export type CommentsVariables = AuthVariables;

const BODY_MIN = 1;
const BODY_MAX = 5000;
const ADMIN_ROLE = 'admin';

type SortKey = 'top' | 'new';

const isValidSort = (s: string): s is SortKey => s === 'top' || s === 'new';

type Db = ReturnType<typeof drizzle>;

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

// The post's current comment tally. Counts hidden (tombstoned) rows too,
// matching the read routes in posts.ts so the create response and the
// feed agree. Returned on the create-comment response so the client can
// reconcile the denormalized count it carries on the post card without a
// separate fetch.
async function loadCommentCount(db: Db, postId: string): Promise<number> {
  const [row] = await db
    .select({ count: count() })
    .from(comments)
    .where(eq(comments.postId, postId));
  return row?.count ?? 0;
}

function commentResponse(
  c: Comment,
  author?: Pick<Profile, 'username' | 'displayName' | 'avatarUrl'>,
) {
  if (c.hidden) {
    // Reddit-style placeholder: preserve tree shape (id, parent,
    // depth) but strip everything that could leak author or text.
    // Also strip crisis_flagged so a moderated row doesn't broadcast
    // its triage state to readers. Author name fields are nulled
    // alongside author_id so a moderated row never leaks its author.
    return {
      id: c.id,
      post_id: c.postId,
      parent_comment_id: c.parentCommentId,
      author_id: null,
      author_username: null,
      author_display_name: null,
      body: null,
      created_at: c.createdAt.toISOString(),
      vote_count: 0,
      depth: c.depth,
      hidden: true,
    };
  }
  return {
    id: c.id,
    post_id: c.postId,
    parent_comment_id: c.parentCommentId,
    author_id: c.authorId,
    author_username: author?.username ?? null,
    author_display_name: author?.displayName ?? null,
    author_avatar_url: author?.avatarUrl ?? null,
    body: c.body,
    created_at: c.createdAt.toISOString(),
    vote_count: c.voteCount,
    depth: c.depth,
    hidden: false,
    // crisis_flagged is deliberately NOT exposed — see postResponse in
    // posts.ts (the triage state is private to the author, moderators,
    // and the watchdog).
  };
}

// Build a profileId -> {username, displayName} lookup for a batch of
// comments so the list endpoint attaches author names with a single
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

export const commentsRouter = () => {
  const router = new Hono<{
    Bindings: CommentsBindings;
    Variables: CommentsVariables;
  }>();

  // ---------- Public read ----------

  router.get('/posts/:post_id/comments', async (c) => {
    const db = drizzle(c.env.FORUM_DB);

    const post = await loadVisiblePost(db, c.req.param('post_id'));
    if (!post) {
      return c.json({ error: 'post_not_found' }, 404);
    }

    const sortParam = c.req.query('sort') ?? 'top';
    if (!isValidSort(sortParam)) {
      return c.json({ error: 'invalid_sort' }, 400);
    }
    const sort = sortParam;

    // Flat fetch — the client reconstructs the tree by walking
    // parent_comment_id. Hidden rows stay in the result so reply
    // chains stitched beneath a moderated parent still surface.
    const rows = await db
      .select()
      .from(comments)
      .where(eq(comments.postId, post.id))
      .orderBy(
        sort === 'top'
          ? desc(comments.voteCount)
          : desc(comments.createdAt),
        // Stable tiebreak — older first for top, older-first-then-id
        // for new so the dataset paginates the same way each call.
        sort === 'top' ? asc(comments.createdAt) : asc(comments.id),
      );

    // Hidden rows have their author nulled in the response, so only
    // non-hidden authors need a name lookup.
    const authors = await loadAuthors(
      db,
      rows.filter((r) => !r.hidden).map((r) => r.authorId),
    );
    return c.json(
      {
        comments: rows.map((r) =>
          commentResponse(r, authors.get(r.authorId)),
        ),
      },
      200,
    );
  });

  // ---------- Authed writes ----------

  router.post('/posts/:post_id/comments', auth(), async (c) => {
    const db = drizzle(c.env.FORUM_DB);

    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    const post = await loadVisiblePost(db, c.req.param('post_id'));
    if (!post) {
      return c.json({ error: 'post_not_found' }, 404);
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
    const { body, parent_comment_id } = raw as {
      body?: unknown;
      parent_comment_id?: unknown;
    };

    if (
      typeof body !== 'string' ||
      body.length < BODY_MIN ||
      body.length > BODY_MAX
    ) {
      return c.json({ error: 'invalid_body_text' }, 400);
    }

    let depth = 0;
    let parentId: string | null = null;
    if (parent_comment_id !== undefined && parent_comment_id !== null) {
      if (typeof parent_comment_id !== 'string') {
        return c.json({ error: 'invalid_parent' }, 400);
      }
      const [parent] = await db
        .select()
        .from(comments)
        .where(eq(comments.id, parent_comment_id));
      // Can't reply to a parent that doesn't exist, lives under a
      // different post, or has been moderated away — that would
      // produce orphaned or zombie subtrees.
      if (!parent || parent.postId !== post.id || parent.hidden) {
        return c.json({ error: 'parent_not_found' }, 404);
      }
      depth = parent.depth + 1;
      parentId = parent.id;
    }

    if (depth > MAX_COMMENT_DEPTH) {
      return c.json(
        {
          error: 'max_depth_exceeded',
          message: `Replies are capped at ${MAX_COMMENT_DEPTH} levels deep.`,
        },
        400,
      );
    }

    const detection = detectCrisisContent(body);

    const [created] = await db
      .insert(comments)
      .values({
        postId: post.id,
        authorId: profile.id,
        parentCommentId: parentId,
        body,
        depth,
        crisisFlagged: detection.flagged,
      })
      .returning();
    const payload: Record<string, unknown> = commentResponse(created, profile);
    // The post's updated comment tally rides along on the create
    // response so the client can sync the denormalized count on the
    // post card without a follow-up fetch. Counted AFTER the insert so
    // it includes this new row.
    payload.comment_count = await loadCommentCount(db, post.id);
    if (detection.flagged) {
      payload.crisis_resources = detection.resources;
    }
    return c.json(payload, 201);
  });

  router.delete('/comments/:id', auth(), async (c) => {
    const db = drizzle(c.env.FORUM_DB);

    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    const [existing] = await db
      .select()
      .from(comments)
      .where(eq(comments.id, c.req.param('id')));
    if (!existing || existing.hidden) {
      return c.json({ error: 'comment_not_found' }, 404);
    }
    if (
      existing.authorId !== profile.id &&
      profile.role !== ADMIN_ROLE
    ) {
      return c.json({ error: 'forbidden' }, 403);
    }

    await db
      .update(comments)
      .set({ hidden: true })
      .where(eq(comments.id, existing.id));
    return c.json({ id: existing.id, hidden: true }, 200);
  });

  return router;
};


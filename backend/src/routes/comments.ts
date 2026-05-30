import { asc, desc, eq } from 'drizzle-orm';
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
  careblazersUserId: string,
): Promise<Profile | undefined> {
  const [row] = await db
    .select()
    .from(profiles)
    .where(eq(profiles.careblazersUserId, careblazersUserId));
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

function commentResponse(c: Comment) {
  if (c.hidden) {
    // Reddit-style placeholder: preserve tree shape (id, parent,
    // depth) but strip everything that could leak author or text.
    // Also strip crisis_flagged so a moderated row doesn't broadcast
    // its triage state to readers.
    return {
      id: c.id,
      post_id: c.postId,
      parent_comment_id: c.parentCommentId,
      author_id: null,
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
    body: c.body,
    created_at: c.createdAt.toISOString(),
    vote_count: c.voteCount,
    depth: c.depth,
    hidden: false,
    crisis_flagged: c.crisisFlagged,
  };
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

    return c.json({ comments: rows.map(commentResponse) }, 200);
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
    const payload: Record<string, unknown> = commentResponse(created);
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


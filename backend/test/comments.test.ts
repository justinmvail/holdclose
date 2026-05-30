import { SELF, env } from 'cloudflare:test';
import { eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

import {
  comments,
  MAX_COMMENT_DEPTH,
  posts,
  profiles,
  type Comment,
  type Post,
  type Profile,
} from '../src/db/schema';

const SECRET = env.FORUM_JWT_SECRET;
const ORIGIN = 'https://forum.careblazers.local';

const nowSec = () => Math.floor(Date.now() / 1000);

async function mintToken(sub: string) {
  const iat = nowSec();
  return sign({ sub, iat, exp: iat + 3600 }, SECRET, 'HS256');
}

async function authedFetch(
  path: string,
  init: RequestInit & { sub: string },
) {
  const token = await mintToken(init.sub);
  return SELF.fetch(`${ORIGIN}${path}`, {
    ...init,
    headers: {
      ...(init.headers ?? {}),
      Authorization: `Bearer ${token}`,
    },
  });
}

async function clearTables() {
  await env.FORUM_DB.batch([
    env.FORUM_DB.prepare('DELETE FROM reports'),
    env.FORUM_DB.prepare('DELETE FROM votes'),
    env.FORUM_DB.prepare('DELETE FROM comments'),
    env.FORUM_DB.prepare('DELETE FROM posts'),
    env.FORUM_DB.prepare('DELETE FROM profiles'),
  ]);
}

async function makeProfile(
  sub: string,
  options: { role?: 'user' | 'admin'; displayName?: string } = {},
): Promise<Profile> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db
    .insert(profiles)
    .values({
      displayName: options.displayName ?? sub,
      careblazersUserId: sub,
      role: options.role ?? 'user',
    })
    .returning();
  return row;
}

async function seedPost(values: {
  authorId: string;
  title?: string;
  body?: string;
  hidden?: boolean;
}): Promise<Post> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db
    .insert(posts)
    .values({
      authorId: values.authorId,
      title: values.title ?? 'host',
      body: values.body ?? 'body',
      hidden: values.hidden ?? false,
    })
    .returning();
  return row;
}

async function seedComment(values: {
  postId: string;
  authorId: string;
  body?: string;
  parentCommentId?: string | null;
  depth?: number;
  voteCount?: number;
  createdAt?: Date;
  hidden?: boolean;
}): Promise<Comment> {
  const db = drizzle(env.FORUM_DB);
  const createdAt = values.createdAt ?? new Date();
  const [row] = await db
    .insert(comments)
    .values({
      postId: values.postId,
      authorId: values.authorId,
      parentCommentId: values.parentCommentId ?? null,
      body: values.body ?? 'comment',
      depth: values.depth ?? 0,
      voteCount: values.voteCount ?? 0,
      createdAt,
      hidden: values.hidden ?? false,
    })
    .returning();
  return row;
}

beforeEach(async () => {
  await clearTables();
});

// ---------- GET /api/v1/posts/:post_id/comments ----------

describe('GET /api/v1/posts/:post_id/comments', () => {
  it('is reachable without a token', async () => {
    const author = await makeProfile('cb-cmts-anon');
    const post = await seedPost({ authorId: author.id });
    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/${post.id}/comments`,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ comments: [] });
  });

  it('returns 404 when the post does not exist', async () => {
    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/does-not-exist/comments`,
    );
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'post_not_found' });
  });

  it('returns 404 when the post is hidden', async () => {
    const author = await makeProfile('cb-cmts-hidden-host');
    const hidden = await seedPost({ authorId: author.id, hidden: true });
    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/${hidden.id}/comments`,
    );
    expect(res.status).toBe(404);
  });

  it('returns 400 for an unknown sort', async () => {
    const author = await makeProfile('cb-cmts-bad-sort');
    const post = await seedPost({ authorId: author.id });
    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/${post.id}/comments?sort=spicy`,
    );
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_sort' });
  });

  it('defaults sort to top when sort is omitted', async () => {
    const author = await makeProfile('cb-cmts-default-sort');
    const post = await seedPost({ authorId: author.id });
    const lo = await seedComment({
      postId: post.id,
      authorId: author.id,
      body: 'lo',
      voteCount: 1,
    });
    const hi = await seedComment({
      postId: post.id,
      authorId: author.id,
      body: 'hi',
      voteCount: 99,
    });

    const explicit = await (
      await SELF.fetch(
        `${ORIGIN}/api/v1/posts/${post.id}/comments?sort=top`,
      )
    ).json();
    const implicit = await (
      await SELF.fetch(`${ORIGIN}/api/v1/posts/${post.id}/comments`)
    ).json();
    expect(implicit).toEqual(explicit);
    const body = implicit as { comments: { id: string }[] };
    expect(body.comments.map((c) => c.id)).toEqual([hi.id, lo.id]);
  });

  it('sort=new orders comments by created_at DESC', async () => {
    const author = await makeProfile('cb-cmts-new');
    const post = await seedPost({ authorId: author.id });
    const base = Date.now();
    const oldest = await seedComment({
      postId: post.id,
      authorId: author.id,
      body: 'old',
      createdAt: new Date(base - 60_000),
    });
    const newest = await seedComment({
      postId: post.id,
      authorId: author.id,
      body: 'new',
      createdAt: new Date(base),
    });
    const middle = await seedComment({
      postId: post.id,
      authorId: author.id,
      body: 'mid',
      createdAt: new Date(base - 30_000),
    });

    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/${post.id}/comments?sort=new`,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { comments: { id: string }[] };
    expect(body.comments.map((c) => c.id)).toEqual([
      newest.id,
      middle.id,
      oldest.id,
    ]);
  });

  it('sort=top orders comments by vote_count DESC', async () => {
    const author = await makeProfile('cb-cmts-top');
    const post = await seedPost({ authorId: author.id });
    const lo = await seedComment({
      postId: post.id,
      authorId: author.id,
      voteCount: 1,
    });
    const hi = await seedComment({
      postId: post.id,
      authorId: author.id,
      voteCount: 99,
    });
    const mid = await seedComment({
      postId: post.id,
      authorId: author.id,
      voteCount: 12,
    });

    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/${post.id}/comments?sort=top`,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { comments: { id: string }[] };
    expect(body.comments.map((c) => c.id)).toEqual([hi.id, mid.id, lo.id]);
  });

  it('omits comments belonging to other posts', async () => {
    const author = await makeProfile('cb-cmts-cross');
    const a = await seedPost({ authorId: author.id, title: 'A' });
    const b = await seedPost({ authorId: author.id, title: 'B' });
    const onA = await seedComment({
      postId: a.id,
      authorId: author.id,
      body: 'on A',
    });
    await seedComment({
      postId: b.id,
      authorId: author.id,
      body: 'on B',
    });

    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/${a.id}/comments`,
    );
    const body = (await res.json()) as { comments: { id: string }[] };
    expect(body.comments.map((c) => c.id)).toEqual([onA.id]);
  });

  it('keeps hidden comments in the tree but masks body + author', async () => {
    const author = await makeProfile('cb-cmts-hidden');
    const post = await seedPost({ authorId: author.id });
    const root = await seedComment({
      postId: post.id,
      authorId: author.id,
      body: 'visible root',
    });
    const moderated = await seedComment({
      postId: post.id,
      authorId: author.id,
      parentCommentId: root.id,
      depth: 1,
      body: 'secret text',
      voteCount: 7,
      hidden: true,
    });
    const child = await seedComment({
      postId: post.id,
      authorId: author.id,
      parentCommentId: moderated.id,
      depth: 2,
      body: 'reply under moderated',
    });

    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/${post.id}/comments?sort=new`,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      comments: Array<{
        id: string;
        hidden: boolean;
        body: string | null;
        author_id: string | null;
        depth: number;
        parent_comment_id: string | null;
      }>;
    };

    const byId = Object.fromEntries(body.comments.map((c) => [c.id, c]));
    expect(byId[root.id].hidden).toBe(false);
    expect(byId[root.id].body).toBe('visible root');

    expect(byId[moderated.id].hidden).toBe(true);
    expect(byId[moderated.id].body).toBeNull();
    expect(byId[moderated.id].author_id).toBeNull();
    expect(byId[moderated.id].depth).toBe(1);
    expect(byId[moderated.id].parent_comment_id).toBe(root.id);

    // Child of a hidden parent still surfaces so the tree shape
    // remains intact.
    expect(byId[child.id].hidden).toBe(false);
    expect(byId[child.id].parent_comment_id).toBe(moderated.id);
  });

  it('populates depth on every row in the flat list', async () => {
    const author = await makeProfile('cb-cmts-depth');
    const post = await seedPost({ authorId: author.id });
    const root = await seedComment({
      postId: post.id,
      authorId: author.id,
      depth: 0,
    });
    const d1 = await seedComment({
      postId: post.id,
      authorId: author.id,
      parentCommentId: root.id,
      depth: 1,
    });
    const d2 = await seedComment({
      postId: post.id,
      authorId: author.id,
      parentCommentId: d1.id,
      depth: 2,
    });

    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/${post.id}/comments?sort=new`,
    );
    const body = (await res.json()) as {
      comments: Array<{ id: string; depth: number }>;
    };
    const byId = Object.fromEntries(body.comments.map((c) => [c.id, c]));
    expect(byId[root.id].depth).toBe(0);
    expect(byId[d1.id].depth).toBe(1);
    expect(byId[d2.id].depth).toBe(2);
  });
});

// ---------- POST /api/v1/posts/:post_id/comments ----------

describe('POST /api/v1/posts/:post_id/comments', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/anything/comments`,
      { method: 'POST' },
    );
    expect(res.status).toBe(401);
  });

  it('returns 404 when the authed user has no profile yet', async () => {
    const res = await authedFetch('/api/v1/posts/anything/comments', {
      method: 'POST',
      sub: 'cb-cmts-no-profile',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: 'hello' }),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it('returns 404 when the post does not exist', async () => {
    await makeProfile('cb-cmts-missing-post');
    const res = await authedFetch(
      '/api/v1/posts/does-not-exist/comments',
      {
        method: 'POST',
        sub: 'cb-cmts-missing-post',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ body: 'hello' }),
      },
    );
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'post_not_found' });
  });

  it('returns 404 when the post is hidden', async () => {
    const author = await makeProfile('cb-cmts-hidden-post');
    const hidden = await seedPost({ authorId: author.id, hidden: true });
    const res = await authedFetch(
      `/api/v1/posts/${hidden.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-hidden-post',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ body: 'on a corpse' }),
      },
    );
    expect(res.status).toBe(404);
  });

  it('returns 400 when the request body is not JSON', async () => {
    const author = await makeProfile('cb-cmts-bad-json');
    const post = await seedPost({ authorId: author.id });
    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-bad-json',
        headers: { 'Content-Type': 'application/json' },
        body: 'not-json',
      },
    );
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_body' });
  });

  it.each([
    ['', 'empty'],
    ['x'.repeat(5001), 'over 5000 chars'],
  ])('returns 400 when body is %j (%s)', async (body) => {
    const author = await makeProfile('cb-cmts-bad-body');
    const post = await seedPost({ authorId: author.id });
    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-bad-body',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ body }),
      },
    );
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_body_text' });
  });

  it('creates a root comment at depth 0', async () => {
    const author = await makeProfile('cb-cmts-root');
    const post = await seedPost({ authorId: author.id });
    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-root',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ body: 'first thoughts' }),
      },
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      post_id: post.id,
      author_id: author.id,
      body: 'first thoughts',
      depth: 0,
      parent_comment_id: null,
      vote_count: 0,
      hidden: false,
    });
    expect(typeof body.id).toBe('string');
  });

  it('computes depth from the parent on a nested reply', async () => {
    const author = await makeProfile('cb-cmts-nested');
    const post = await seedPost({ authorId: author.id });
    const root = await seedComment({
      postId: post.id,
      authorId: author.id,
      depth: 0,
    });

    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-nested',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'a reply',
          parent_comment_id: root.id,
        }),
      },
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.depth).toBe(1);
    expect(body.parent_comment_id).toBe(root.id);
  });

  it('rejects depth past the cap with a clear message', async () => {
    const author = await makeProfile('cb-cmts-too-deep');
    const post = await seedPost({ authorId: author.id });
    // Build a chain at exactly the cap depth — the next reply must
    // be rejected.
    let parent: Comment | null = null;
    for (let d = 0; d <= MAX_COMMENT_DEPTH; d++) {
      parent = await seedComment({
        postId: post.id,
        authorId: author.id,
        parentCommentId: parent?.id ?? null,
        depth: d,
      });
    }

    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-too-deep',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'one too far',
          parent_comment_id: parent!.id,
        }),
      },
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string; message: string };
    expect(body.error).toBe('max_depth_exceeded');
    expect(body.message).toMatch(/6/);
  });

  it('allows replies at exactly the cap depth', async () => {
    const author = await makeProfile('cb-cmts-at-cap');
    const post = await seedPost({ authorId: author.id });
    // Parent at depth 5 → child at depth 6 is the deepest legal write.
    let parent: Comment | null = null;
    for (let d = 0; d < MAX_COMMENT_DEPTH; d++) {
      parent = await seedComment({
        postId: post.id,
        authorId: author.id,
        parentCommentId: parent?.id ?? null,
        depth: d,
      });
    }

    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-at-cap',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'deepest allowed',
          parent_comment_id: parent!.id,
        }),
      },
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as { depth: number };
    expect(body.depth).toBe(MAX_COMMENT_DEPTH);
  });

  it('returns 404 when parent_comment_id does not exist', async () => {
    const author = await makeProfile('cb-cmts-no-parent');
    const post = await seedPost({ authorId: author.id });
    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-no-parent',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'reply to ghost',
          parent_comment_id: 'does-not-exist',
        }),
      },
    );
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'parent_not_found' });
  });

  it('returns 404 when parent_comment_id belongs to a different post', async () => {
    const author = await makeProfile('cb-cmts-cross-parent');
    const a = await seedPost({ authorId: author.id, title: 'A' });
    const b = await seedPost({ authorId: author.id, title: 'B' });
    const onA = await seedComment({
      postId: a.id,
      authorId: author.id,
    });

    const res = await authedFetch(
      `/api/v1/posts/${b.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-cross-parent',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'stolen parent',
          parent_comment_id: onA.id,
        }),
      },
    );
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'parent_not_found' });
  });

  it('returns 404 when parent_comment_id is itself hidden', async () => {
    const author = await makeProfile('cb-cmts-hidden-parent');
    const post = await seedPost({ authorId: author.id });
    const hidden = await seedComment({
      postId: post.id,
      authorId: author.id,
      hidden: true,
    });

    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-hidden-parent',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'should not stitch under a tombstone',
          parent_comment_id: hidden.id,
        }),
      },
    );
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'parent_not_found' });
  });

  it('returns 400 when parent_comment_id is the wrong type', async () => {
    const author = await makeProfile('cb-cmts-bad-parent-type');
    const post = await seedPost({ authorId: author.id });
    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-bad-parent-type',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'ok body',
          parent_comment_id: 12345,
        }),
      },
    );
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_parent' });
  });

  it('flags a comment whose body contains a crisis keyword (Phase 13.8)', async () => {
    const author = await makeProfile('cb-cmts-crisis');
    const post = await seedPost({ authorId: author.id });
    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-crisis',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'honestly some nights I want to end it all',
        }),
      },
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      id: string;
      crisis_flagged: boolean;
      crisis_resources?: {
        crisis_card_url: string;
        hotlines: unknown[];
      };
    };
    expect(body.crisis_flagged).toBe(true);
    expect(body.crisis_resources).toBeDefined();
    expect(body.crisis_resources!.crisis_card_url).toBe('/crisis');

    const db = drizzle(env.FORUM_DB);
    const [row] = await db
      .select()
      .from(comments)
      .where(eq(comments.id, body.id));
    expect(row.crisisFlagged).toBe(true);
  });

  it('a benign comment is unflagged and carries no crisis_resources', async () => {
    const author = await makeProfile('cb-cmts-benign');
    const post = await seedPost({ authorId: author.id });
    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-benign',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'we tried scheduled bathroom trips and it really helped',
        }),
      },
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.crisis_flagged).toBe(false);
    expect(body.crisis_resources).toBeUndefined();
  });

  it('treats parent_comment_id=null as a root comment', async () => {
    const author = await makeProfile('cb-cmts-null-parent');
    const post = await seedPost({ authorId: author.id });
    const res = await authedFetch(
      `/api/v1/posts/${post.id}/comments`,
      {
        method: 'POST',
        sub: 'cb-cmts-null-parent',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          body: 'still a root',
          parent_comment_id: null,
        }),
      },
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      depth: number;
      parent_comment_id: string | null;
    };
    expect(body.depth).toBe(0);
    expect(body.parent_comment_id).toBeNull();
  });
});

// ---------- DELETE /api/v1/comments/:id ----------

describe('DELETE /api/v1/comments/:id', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/comments/some-id`, {
      method: 'DELETE',
    });
    expect(res.status).toBe(401);
  });

  it('returns 404 for an unknown comment id', async () => {
    await makeProfile('cb-cmts-del-missing');
    const res = await authedFetch('/api/v1/comments/does-not-exist', {
      method: 'DELETE',
      sub: 'cb-cmts-del-missing',
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'comment_not_found' });
  });

  it('returns 404 when the comment is already hidden', async () => {
    const author = await makeProfile('cb-cmts-del-hidden');
    const post = await seedPost({ authorId: author.id });
    const tombstone = await seedComment({
      postId: post.id,
      authorId: author.id,
      hidden: true,
    });
    const res = await authedFetch(
      `/api/v1/comments/${tombstone.id}`,
      {
        method: 'DELETE',
        sub: 'cb-cmts-del-hidden',
      },
    );
    expect(res.status).toBe(404);
  });

  it('returns 403 when caller is neither author nor admin', async () => {
    const author = await makeProfile('cb-cmts-del-owner');
    await makeProfile('cb-cmts-del-stranger');
    const post = await seedPost({ authorId: author.id });
    const target = await seedComment({
      postId: post.id,
      authorId: author.id,
    });

    const res = await authedFetch(`/api/v1/comments/${target.id}`, {
      method: 'DELETE',
      sub: 'cb-cmts-del-stranger',
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: 'forbidden' });
  });

  it('lets the author soft-delete', async () => {
    const author = await makeProfile('cb-cmts-del-author');
    const post = await seedPost({ authorId: author.id });
    const target = await seedComment({
      postId: post.id,
      authorId: author.id,
    });

    const res = await authedFetch(`/api/v1/comments/${target.id}`, {
      method: 'DELETE',
      sub: 'cb-cmts-del-author',
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ id: target.id, hidden: true });

    const db = drizzle(env.FORUM_DB);
    const [row] = await db
      .select()
      .from(comments)
      .where(eq(comments.id, target.id));
    expect(row.hidden).toBe(true);
    // Soft-delete preserves the row so its replies still anchor.
    expect(row.body).toBe('comment');
  });

  it('lets an admin soft-delete a comment they did not author', async () => {
    const author = await makeProfile('cb-cmts-del-victim');
    await makeProfile('cb-cmts-del-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });
    const target = await seedComment({
      postId: post.id,
      authorId: author.id,
    });

    const res = await authedFetch(`/api/v1/comments/${target.id}`, {
      method: 'DELETE',
      sub: 'cb-cmts-del-admin',
    });
    expect(res.status).toBe(200);

    const db = drizzle(env.FORUM_DB);
    const [row] = await db
      .select()
      .from(comments)
      .where(eq(comments.id, target.id));
    expect(row.hidden).toBe(true);
  });

  it('after delete, the comment renders as a tombstone in the thread', async () => {
    const author = await makeProfile('cb-cmts-del-tombstone');
    const post = await seedPost({ authorId: author.id });
    const target = await seedComment({
      postId: post.id,
      authorId: author.id,
      body: 'about to vanish',
    });

    await authedFetch(`/api/v1/comments/${target.id}`, {
      method: 'DELETE',
      sub: 'cb-cmts-del-tombstone',
    });

    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts/${post.id}/comments?sort=new`,
    );
    const body = (await res.json()) as {
      comments: Array<{
        id: string;
        hidden: boolean;
        body: string | null;
        author_id: string | null;
      }>;
    };
    expect(body.comments).toHaveLength(1);
    expect(body.comments[0]).toMatchObject({
      id: target.id,
      hidden: true,
      body: null,
      author_id: null,
    });
  });
});

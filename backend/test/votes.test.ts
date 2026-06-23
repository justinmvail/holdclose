import { SELF, env } from 'cloudflare:test';
import { and, eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

import {
  comments,
  posts,
  profiles,
  votes,
  type Comment,
  type Post,
  type Profile,
} from '../src/db/schema';

const SECRET = env.FORUM_JWT_SECRET;
const ORIGIN = 'https://forum.holdclose.local';

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

async function castVote(
  sub: string,
  payload: { target_kind: string; target_id: string; value: number },
) {
  return authedFetch('/api/v1/votes', {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
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
  options: { displayName?: string } = {},
): Promise<Profile> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db
    .insert(profiles)
    .values({
      displayName: options.displayName ?? sub,
      careblazersUserId: sub,
    })
    .returning();
  return row;
}

async function seedPost(values: {
  authorId: string;
  title?: string;
  body?: string;
  voteCount?: number;
  hidden?: boolean;
}): Promise<Post> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db
    .insert(posts)
    .values({
      authorId: values.authorId,
      title: values.title ?? 'post',
      body: values.body ?? 'body',
      voteCount: values.voteCount ?? 0,
      hidden: values.hidden ?? false,
    })
    .returning();
  return row;
}

async function seedComment(values: {
  postId: string;
  authorId: string;
  body?: string;
  voteCount?: number;
  hidden?: boolean;
}): Promise<Comment> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db
    .insert(comments)
    .values({
      postId: values.postId,
      authorId: values.authorId,
      body: values.body ?? 'comment',
      voteCount: values.voteCount ?? 0,
      hidden: values.hidden ?? false,
    })
    .returning();
  return row;
}

async function postVoteCount(id: string): Promise<number> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db.select().from(posts).where(eq(posts.id, id));
  return row.voteCount;
}

async function commentVoteCount(id: string): Promise<number> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db.select().from(comments).where(eq(comments.id, id));
  return row.voteCount;
}

async function voteRow(
  voterId: string,
  targetKind: 'post' | 'comment',
  targetId: string,
) {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db
    .select()
    .from(votes)
    .where(
      and(
        eq(votes.voterId, voterId),
        eq(votes.targetKind, targetKind),
        eq(votes.targetId, targetId),
      ),
    );
  return row;
}

beforeEach(async () => {
  await clearTables();
});

// ---------- auth / validation ----------

describe('POST /api/v1/votes — auth + validation', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/votes`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(401);
  });

  it('returns 404 when the authed user has no profile yet', async () => {
    const res = await castVote('cb-vote-no-profile', {
      target_kind: 'post',
      target_id: 'anything',
      value: 1,
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it('returns 400 when the request body is not JSON', async () => {
    await makeProfile('cb-vote-bad-json');
    const res = await authedFetch('/api/v1/votes', {
      method: 'POST',
      sub: 'cb-vote-bad-json',
      headers: { 'Content-Type': 'application/json' },
      body: 'not-json',
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_body' });
  });

  it('returns 400 when the body is a JSON primitive', async () => {
    await makeProfile('cb-vote-prim');
    const res = await authedFetch('/api/v1/votes', {
      method: 'POST',
      sub: 'cb-vote-prim',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(7),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_body' });
  });

  it('returns 400 for an unknown target_kind', async () => {
    await makeProfile('cb-vote-bad-kind');
    const res = await castVote('cb-vote-bad-kind', {
      target_kind: 'post-thread',
      target_id: 'x',
      value: 1,
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_target_kind' });
  });

  it.each(['', 0, null, undefined])(
    'returns 400 for invalid target_id %j',
    async (target_id) => {
      await makeProfile('cb-vote-bad-id');
      const res = await authedFetch('/api/v1/votes', {
        method: 'POST',
        sub: 'cb-vote-bad-id',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          target_kind: 'post',
          target_id,
          value: 1,
        }),
      });
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: 'invalid_target_id' });
    },
  );

  it.each([2, -2, 0.5, '1', null])(
    'returns 400 for invalid value %j',
    async (value) => {
      const voter = await makeProfile('cb-vote-bad-val');
      const post = await seedPost({ authorId: voter.id });
      const res = await authedFetch('/api/v1/votes', {
        method: 'POST',
        sub: 'cb-vote-bad-val',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          target_kind: 'post',
          target_id: post.id,
          value,
        }),
      });
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: 'invalid_value' });
    },
  );
});

// ---------- target visibility ----------

describe('POST /api/v1/votes — target visibility', () => {
  it('returns 404 when the target post does not exist', async () => {
    await makeProfile('cb-vote-missing-post');
    const res = await castVote('cb-vote-missing-post', {
      target_kind: 'post',
      target_id: 'does-not-exist',
      value: 1,
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'target_not_found' });
  });

  it('returns 404 when the target post is hidden', async () => {
    const voter = await makeProfile('cb-vote-hidden-post');
    const hidden = await seedPost({ authorId: voter.id, hidden: true });
    const res = await castVote('cb-vote-hidden-post', {
      target_kind: 'post',
      target_id: hidden.id,
      value: 1,
    });
    expect(res.status).toBe(404);
  });

  it('returns 404 when the target comment does not exist', async () => {
    await makeProfile('cb-vote-missing-cmt');
    const res = await castVote('cb-vote-missing-cmt', {
      target_kind: 'comment',
      target_id: 'does-not-exist',
      value: 1,
    });
    expect(res.status).toBe(404);
  });

  it('returns 404 when the target comment is hidden', async () => {
    const voter = await makeProfile('cb-vote-hidden-cmt');
    const post = await seedPost({ authorId: voter.id });
    const hidden = await seedComment({
      postId: post.id,
      authorId: voter.id,
      hidden: true,
    });
    const res = await castVote('cb-vote-hidden-cmt', {
      target_kind: 'comment',
      target_id: hidden.id,
      value: 1,
    });
    expect(res.status).toBe(404);
  });
});

// ---------- vote mechanics on posts ----------

describe('POST /api/v1/votes — post mechanics', () => {
  it('upvotes a post: inserts vote row and increments counter', async () => {
    const voter = await makeProfile('cb-vote-up');
    const post = await seedPost({ authorId: voter.id, voteCount: 4 });

    const res = await castVote('cb-vote-up', {
      target_kind: 'post',
      target_id: post.id,
      value: 1,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ vote_count: 5, value: 1 });

    expect(await postVoteCount(post.id)).toBe(5);
    const v = await voteRow(voter.id, 'post', post.id);
    expect(v.value).toBe(1);
  });

  it('downvotes a post', async () => {
    const voter = await makeProfile('cb-vote-down');
    const post = await seedPost({ authorId: voter.id, voteCount: 4 });

    const res = await castVote('cb-vote-down', {
      target_kind: 'post',
      target_id: post.id,
      value: -1,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ vote_count: 3, value: -1 });
    expect(await postVoteCount(post.id)).toBe(3);
  });

  it('switching +1 to -1 produces a single net change of -2', async () => {
    const voter = await makeProfile('cb-vote-switch');
    const post = await seedPost({ authorId: voter.id, voteCount: 0 });

    let res = await castVote('cb-vote-switch', {
      target_kind: 'post',
      target_id: post.id,
      value: 1,
    });
    expect(await res.json()).toMatchObject({ vote_count: 1 });

    res = await castVote('cb-vote-switch', {
      target_kind: 'post',
      target_id: post.id,
      value: -1,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ vote_count: -1, value: -1 });

    // Only one row should still exist for this voter+target.
    const db = drizzle(env.FORUM_DB);
    const rows = await db
      .select()
      .from(votes)
      .where(
        and(
          eq(votes.voterId, voter.id),
          eq(votes.targetKind, 'post'),
          eq(votes.targetId, post.id),
        ),
      );
    expect(rows).toHaveLength(1);
    expect(rows[0].value).toBe(-1);
    expect(await postVoteCount(post.id)).toBe(-1);
  });

  it('value=0 with an existing vote withdraws it and reverts the counter', async () => {
    const voter = await makeProfile('cb-vote-zero');
    const post = await seedPost({ authorId: voter.id, voteCount: 0 });

    await castVote('cb-vote-zero', {
      target_kind: 'post',
      target_id: post.id,
      value: 1,
    });
    expect(await postVoteCount(post.id)).toBe(1);

    const res = await castVote('cb-vote-zero', {
      target_kind: 'post',
      target_id: post.id,
      value: 0,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ vote_count: 0, value: 0 });
    expect(await postVoteCount(post.id)).toBe(0);
    expect(await voteRow(voter.id, 'post', post.id)).toBeUndefined();
  });

  it('value=0 with no existing vote is a no-op', async () => {
    const voter = await makeProfile('cb-vote-zero-noop');
    const post = await seedPost({ authorId: voter.id, voteCount: 9 });

    const res = await castVote('cb-vote-zero-noop', {
      target_kind: 'post',
      target_id: post.id,
      value: 0,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ vote_count: 9, value: 0 });
    expect(await postVoteCount(post.id)).toBe(9);
    expect(await voteRow(voter.id, 'post', post.id)).toBeUndefined();
  });

  it('same value as existing is a no-op (no double counting)', async () => {
    const voter = await makeProfile('cb-vote-same');
    const post = await seedPost({ authorId: voter.id, voteCount: 0 });

    await castVote('cb-vote-same', {
      target_kind: 'post',
      target_id: post.id,
      value: 1,
    });
    const res = await castVote('cb-vote-same', {
      target_kind: 'post',
      target_id: post.id,
      value: 1,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ vote_count: 1, value: 1 });
    expect(await postVoteCount(post.id)).toBe(1);
  });

  it('two voters on the same post both stick (count sums correctly)', async () => {
    const author = await makeProfile('cb-vote-author');
    await makeProfile('cb-vote-alice');
    await makeProfile('cb-vote-bob');
    const post = await seedPost({ authorId: author.id, voteCount: 0 });

    await castVote('cb-vote-alice', {
      target_kind: 'post',
      target_id: post.id,
      value: 1,
    });
    await castVote('cb-vote-bob', {
      target_kind: 'post',
      target_id: post.id,
      value: 1,
    });
    expect(await postVoteCount(post.id)).toBe(2);
  });

  it('votes on different targets do not affect each other', async () => {
    const voter = await makeProfile('cb-vote-isolation');
    const a = await seedPost({ authorId: voter.id, voteCount: 0, title: 'a' });
    const b = await seedPost({ authorId: voter.id, voteCount: 0, title: 'b' });

    await castVote('cb-vote-isolation', {
      target_kind: 'post',
      target_id: a.id,
      value: 1,
    });
    await castVote('cb-vote-isolation', {
      target_kind: 'post',
      target_id: b.id,
      value: -1,
    });
    expect(await postVoteCount(a.id)).toBe(1);
    expect(await postVoteCount(b.id)).toBe(-1);
  });
});

// ---------- vote mechanics on comments ----------

describe('POST /api/v1/votes — comment mechanics', () => {
  it('upvotes a comment and the comment counter moves', async () => {
    const voter = await makeProfile('cb-vote-cmt-up');
    const post = await seedPost({ authorId: voter.id });
    const comment = await seedComment({
      postId: post.id,
      authorId: voter.id,
      voteCount: 2,
    });

    const res = await castVote('cb-vote-cmt-up', {
      target_kind: 'comment',
      target_id: comment.id,
      value: 1,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ vote_count: 3, value: 1 });
    expect(await commentVoteCount(comment.id)).toBe(3);
  });

  it('voting on a comment does not touch its parent post counter', async () => {
    const voter = await makeProfile('cb-vote-cmt-isolation');
    const post = await seedPost({ authorId: voter.id, voteCount: 7 });
    const comment = await seedComment({
      postId: post.id,
      authorId: voter.id,
      voteCount: 0,
    });

    await castVote('cb-vote-cmt-isolation', {
      target_kind: 'comment',
      target_id: comment.id,
      value: 1,
    });
    expect(await commentVoteCount(comment.id)).toBe(1);
    expect(await postVoteCount(post.id)).toBe(7);
  });
});

// ---------- concurrency ----------

describe('POST /api/v1/votes — concurrency', () => {
  it('interleaved concurrent voters keep vote_count accurate', async () => {
    const author = await makeProfile('cb-vote-conc-author');
    const post = await seedPost({ authorId: author.id, voteCount: 0 });

    const N = 20;
    const voterSubs: string[] = [];
    for (let i = 0; i < N; i++) {
      const sub = `cb-vote-conc-${i}`;
      await makeProfile(sub);
      voterSubs.push(sub);
    }

    // Each voter +1 in parallel. The unique constraint on
    // (voter, target_kind, target_id) keeps the same voter from
    // double-counting; the SQL `vote_count + delta` update keeps
    // the counter linear regardless of interleave order.
    const results = await Promise.all(
      voterSubs.map((sub) =>
        castVote(sub, {
          target_kind: 'post',
          target_id: post.id,
          value: 1,
        }),
      ),
    );
    for (const res of results) {
      expect(res.status).toBe(200);
    }
    expect(await postVoteCount(post.id)).toBe(N);

    // Half of them switch to -1 — net change per switcher is -2.
    const switchers = voterSubs.slice(0, N / 2);
    const switchResults = await Promise.all(
      switchers.map((sub) =>
        castVote(sub, {
          target_kind: 'post',
          target_id: post.id,
          value: -1,
        }),
      ),
    );
    for (const res of switchResults) {
      expect(res.status).toBe(200);
    }
    // N (initial) + (N/2)*(-2) = N - N = 0.
    expect(await postVoteCount(post.id)).toBe(0);

    // And every voter still has exactly one row.
    const db = drizzle(env.FORUM_DB);
    const rows = await db
      .select()
      .from(votes)
      .where(
        and(eq(votes.targetKind, 'post'), eq(votes.targetId, post.id)),
      );
    expect(rows).toHaveLength(N);
  });
});

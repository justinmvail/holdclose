import { SELF, env } from 'cloudflare:test';
import { eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

import { posts, profiles, type Post, type Profile } from '../src/db/schema';

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
  options: {
    role?: 'user' | 'admin';
    displayName?: string;
    username?: string;
  } = {},
): Promise<Profile> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db
    .insert(profiles)
    .values({
      displayName: options.displayName ?? sub,
      username: options.username ?? null,
      careblazersUserId: sub,
      role: options.role ?? 'user',
    })
    .returning();
  return row;
}

type SeedPost = {
  authorId: string;
  title: string;
  body: string;
  voteCount?: number;
  createdAt?: Date;
  hidden?: boolean;
};

async function seedPost(values: SeedPost): Promise<Post> {
  const db = drizzle(env.FORUM_DB);
  const createdAt = values.createdAt ?? new Date();
  const [row] = await db
    .insert(posts)
    .values({
      authorId: values.authorId,
      title: values.title,
      body: values.body,
      voteCount: values.voteCount ?? 0,
      createdAt,
      updatedAt: createdAt,
      hidden: values.hidden ?? false,
    })
    .returning();
  return row;
}

beforeEach(async () => {
  await clearTables();
});

// ---------- GET /api/v1/posts (list) ----------

describe('GET /api/v1/posts', () => {
  it('is reachable without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ posts: [] });
  });

  it('excludes hidden posts from the feed', async () => {
    const author = await makeProfile('cb-feed-author');
    const visible = await seedPost({
      authorId: author.id,
      title: 'visible',
      body: 'shown',
    });
    await seedPost({
      authorId: author.id,
      title: 'hidden',
      body: 'gone',
      hidden: true,
    });

    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { posts: { id: string }[] };
    expect(body.posts.map((p) => p.id)).toEqual([visible.id]);
  });

  it('returns 400 on an unknown sort', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts?sort=spicy`);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_sort' });
  });

  it.each(['abc', '0', '-5'])(
    'returns 400 when limit is %j',
    async (badLimit) => {
      const res = await SELF.fetch(
        `${ORIGIN}/api/v1/posts?limit=${encodeURIComponent(badLimit)}`,
      );
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: 'invalid_limit' });
    },
  );

  it('caps an over-large limit at 50', async () => {
    const author = await makeProfile('cb-cap');
    // Stagger created_at so the order is deterministic.
    const base = Date.now();
    for (let i = 0; i < 55; i++) {
      await seedPost({
        authorId: author.id,
        title: `t${i}`,
        body: `b${i}`,
        createdAt: new Date(base - i * 1000),
      });
    }

    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts?sort=new&limit=200`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { posts: unknown[] };
    expect(body.posts).toHaveLength(50);
  });

  it('sort=new orders posts by created_at DESC', async () => {
    const author = await makeProfile('cb-new');
    const base = Date.now();
    const oldest = await seedPost({
      authorId: author.id,
      title: 'oldest',
      body: 'b',
      createdAt: new Date(base - 60_000),
    });
    const middle = await seedPost({
      authorId: author.id,
      title: 'middle',
      body: 'b',
      createdAt: new Date(base - 30_000),
    });
    const newest = await seedPost({
      authorId: author.id,
      title: 'newest',
      body: 'b',
      createdAt: new Date(base),
    });

    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts?sort=new`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { posts: { id: string }[] };
    expect(body.posts.map((p) => p.id)).toEqual([
      newest.id,
      middle.id,
      oldest.id,
    ]);
  });

  it('sort=top orders posts by vote_count DESC', async () => {
    const author = await makeProfile('cb-top');
    const lo = await seedPost({
      authorId: author.id,
      title: 'lo',
      body: 'b',
      voteCount: 1,
    });
    const hi = await seedPost({
      authorId: author.id,
      title: 'hi',
      body: 'b',
      voteCount: 99,
    });
    const mid = await seedPost({
      authorId: author.id,
      title: 'mid',
      body: 'b',
      voteCount: 12,
    });

    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts?sort=top`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { posts: { id: string }[] };
    expect(body.posts.map((p) => p.id)).toEqual([hi.id, mid.id, lo.id]);
  });

  it('sort=hot ranks high-vote-older-post above zero-vote-newer-post', async () => {
    const author = await makeProfile('cb-hot');
    const base = Date.now();
    const ancientLowVote = await seedPost({
      authorId: author.id,
      title: 'old-low',
      body: 'b',
      voteCount: 0,
      createdAt: new Date(base - 7_200_000), // 2 hours old
    });
    const freshLowVote = await seedPost({
      authorId: author.id,
      title: 'fresh-low',
      body: 'b',
      voteCount: 0,
      createdAt: new Date(base - 60_000), // 1 minute old
    });
    const oldHighVote = await seedPost({
      authorId: author.id,
      title: 'old-high',
      body: 'b',
      voteCount: 100,
      createdAt: new Date(base - 10_800_000), // 3 hours old
    });

    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts?sort=hot`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { posts: { id: string }[] };
    // Reddit's classic ranking: log10(votes) is worth ~12.5h of age,
    // so 100 votes (order 2) easily outweighs the 3h age gap.
    expect(body.posts.map((p) => p.id)).toEqual([
      oldHighVote.id,
      freshLowVote.id,
      ancientLowVote.id,
    ]);
  });

  it('defaults sort to hot when no sort param is provided', async () => {
    const author = await makeProfile('cb-default-sort');
    const base = Date.now();
    const oldHigh = await seedPost({
      authorId: author.id,
      title: 'old-high',
      body: 'b',
      voteCount: 50,
      createdAt: new Date(base - 10_800_000),
    });
    const freshLow = await seedPost({
      authorId: author.id,
      title: 'fresh-low',
      body: 'b',
      voteCount: 0,
      createdAt: new Date(base - 60_000),
    });

    const explicit = await (
      await SELF.fetch(`${ORIGIN}/api/v1/posts?sort=hot`)
    ).json();
    const implicit = await (await SELF.fetch(`${ORIGIN}/api/v1/posts`)).json();
    expect(implicit).toEqual(explicit);
    const body = implicit as { posts: { id: string }[] };
    expect(body.posts[0].id).toBe(oldHigh.id);
    expect(body.posts[1].id).toBe(freshLow.id);
  });

  it('paginates sort=new past the before cursor', async () => {
    const author = await makeProfile('cb-page');
    const base = Date.now();
    const ids = [];
    for (let i = 0; i < 5; i++) {
      const row = await seedPost({
        authorId: author.id,
        title: `t${i}`,
        body: 'b',
        createdAt: new Date(base - i * 1000),
      });
      ids.push(row.id);
    }
    // ids[0] is newest, ids[4] is oldest.

    const firstPage = (await (
      await SELF.fetch(`${ORIGIN}/api/v1/posts?sort=new&limit=2`)
    ).json()) as { posts: { id: string }[] };
    expect(firstPage.posts.map((p) => p.id)).toEqual([ids[0], ids[1]]);

    const secondPage = (await (
      await SELF.fetch(
        `${ORIGIN}/api/v1/posts?sort=new&limit=2&before=${ids[1]}`,
      )
    ).json()) as { posts: { id: string }[] };
    expect(secondPage.posts.map((p) => p.id)).toEqual([ids[2], ids[3]]);
  });

  it('paginates sort=top past the before cursor', async () => {
    const author = await makeProfile('cb-page-top');
    const a = await seedPost({
      authorId: author.id,
      title: 'a',
      body: 'b',
      voteCount: 50,
    });
    const b = await seedPost({
      authorId: author.id,
      title: 'b',
      body: 'b',
      voteCount: 30,
    });
    const c = await seedPost({
      authorId: author.id,
      title: 'c',
      body: 'b',
      voteCount: 10,
    });

    const firstPage = (await (
      await SELF.fetch(`${ORIGIN}/api/v1/posts?sort=top&limit=1`)
    ).json()) as { posts: { id: string }[] };
    expect(firstPage.posts.map((p) => p.id)).toEqual([a.id]);

    const secondPage = (await (
      await SELF.fetch(
        `${ORIGIN}/api/v1/posts?sort=top&limit=10&before=${a.id}`,
      )
    ).json()) as { posts: { id: string }[] };
    expect(secondPage.posts.map((p) => p.id)).toEqual([b.id, c.id]);
  });

  it('paginates sort=hot past the before cursor', async () => {
    const author = await makeProfile('cb-page-hot');
    const base = Date.now();
    const top = await seedPost({
      authorId: author.id,
      title: 'top',
      body: 'b',
      voteCount: 1000,
      createdAt: new Date(base - 60_000),
    });
    const mid = await seedPost({
      authorId: author.id,
      title: 'mid',
      body: 'b',
      voteCount: 10,
      createdAt: new Date(base - 60_000),
    });
    const low = await seedPost({
      authorId: author.id,
      title: 'low',
      body: 'b',
      voteCount: 0,
      createdAt: new Date(base - 60_000),
    });

    const firstPage = (await (
      await SELF.fetch(`${ORIGIN}/api/v1/posts?sort=hot&limit=1`)
    ).json()) as { posts: { id: string }[] };
    expect(firstPage.posts).toHaveLength(1);
    expect(firstPage.posts[0].id).toBe(top.id);

    const secondPage = (await (
      await SELF.fetch(
        `${ORIGIN}/api/v1/posts?sort=hot&limit=10&before=${top.id}`,
      )
    ).json()) as { posts: { id: string }[] };
    expect(secondPage.posts.map((p) => p.id)).toEqual([mid.id, low.id]);
  });

  it('returns 400 when before references an unknown post', async () => {
    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/posts?before=does-not-exist`,
    );
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_cursor' });
  });
});

// ---------- GET /api/v1/posts/:id ----------

describe('GET /api/v1/posts/:id', () => {
  it('returns 200 for a visible post (read-anonymous)', async () => {
    const author = await makeProfile('cb-single');
    const created = await seedPost({
      authorId: author.id,
      title: 'detail',
      body: 'body',
      voteCount: 7,
    });

    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts/${created.id}`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      id: created.id,
      author_id: author.id,
      title: 'detail',
      body: 'body',
      vote_count: 7,
      hidden: false,
    });
    expect(typeof body.created_at).toBe('string');
    expect(typeof body.updated_at).toBe('string');
  });

  it("carries the author's username + display_name on the response", async () => {
    const author = await makeProfile('cb-named-author', {
      displayName: 'Sarah_H',
      username: 'sarah_h',
    });
    const created = await seedPost({
      authorId: author.id,
      title: 'named',
      body: 'body',
    });

    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts/${created.id}`);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      author_id: author.id,
      author_username: 'sarah_h',
      author_display_name: 'Sarah_H',
    });
  });

  it('nulls author name fields when the author has no username yet', async () => {
    const author = await makeProfile('cb-noname-author', {
      displayName: 'Caregiver_abc123',
    });
    const created = await seedPost({
      authorId: author.id,
      title: 'nameless',
      body: 'body',
    });

    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts/${created.id}`);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.author_username).toBeNull();
    expect(body.author_display_name).toBe('Caregiver_abc123');
  });

  it('returns 404 for an unknown id', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts/missing-id`);
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'post_not_found' });
  });

  it('returns 404 for a hidden post', async () => {
    const author = await makeProfile('cb-hidden');
    const hidden = await seedPost({
      authorId: author.id,
      title: 'gone',
      body: 'gone',
      hidden: true,
    });

    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts/${hidden.id}`);
    expect(res.status).toBe(404);
  });
});

// ---------- POST /api/v1/posts ----------

describe('POST /api/v1/posts', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts`, {
      method: 'POST',
    });
    expect(res.status).toBe(401);
  });

  it('returns 404 when the authed user has no profile yet', async () => {
    const res = await authedFetch('/api/v1/posts', {
      method: 'POST',
      sub: 'cb-no-profile',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: 'hi', body: 'hello' }),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it('returns 400 when the request body is not JSON', async () => {
    await makeProfile('cb-bad-json');
    const res = await authedFetch('/api/v1/posts', {
      method: 'POST',
      sub: 'cb-bad-json',
      headers: { 'Content-Type': 'application/json' },
      body: 'not-json',
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_body' });
  });

  it.each([
    ['', 'empty'],
    ['t'.repeat(201), 'over 200 chars'],
  ])('returns 400 when title is %j (%s)', async (title) => {
    await makeProfile('cb-bad-title');
    const res = await authedFetch('/api/v1/posts', {
      method: 'POST',
      sub: 'cb-bad-title',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title, body: 'fine body' }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_title' });
  });

  it.each([
    ['', 'empty'],
    ['x'.repeat(10001), 'over 10000 chars'],
  ])('returns 400 when body is %j (%s)', async (body) => {
    await makeProfile('cb-bad-body');
    const res = await authedFetch('/api/v1/posts', {
      method: 'POST',
      sub: 'cb-bad-body',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: 'fine title', body }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_body_text' });
  });

  it('creates a post and returns 201', async () => {
    const author = await makeProfile('cb-create');
    const res = await authedFetch('/api/v1/posts', {
      method: 'POST',
      sub: 'cb-create',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        title: 'Sundowning at 4pm',
        body: 'every afternoon, like clockwork',
      }),
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      author_id: author.id,
      title: 'Sundowning at 4pm',
      body: 'every afternoon, like clockwork',
      vote_count: 0,
      hidden: false,
    });
    expect(typeof body.id).toBe('string');
    expect(body.crisis_resources).toBeUndefined();
    // The triage flag is private (author/moderators/watchdog only) —
    // it must not appear on any response (2026-06-11).
    expect(body.crisis_flagged).toBeUndefined();

    const db = drizzle(env.FORUM_DB);
    const rows = await db.select().from(posts);
    expect(rows).toHaveLength(1);
    expect(rows[0].crisisFlagged).toBe(false);
  });

  it('flags a post whose body contains a crisis keyword (Phase 13.8)', async () => {
    await makeProfile('cb-create-crisis');
    const res = await authedFetch('/api/v1/posts', {
      method: 'POST',
      sub: 'cb-create-crisis',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        title: 'I am exhausted',
        body: 'some days I want to kill myself just to get a break',
      }),
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      id: string;
      crisis_flagged?: boolean;
      crisis_resources?: {
        crisis_card_url: string;
        hotlines: Array<{ number: string }>;
      };
    };
    // The flag stays server-side; the author's banner is driven by
    // crisis_resources on THIS create response only (2026-06-11).
    expect(body.crisis_flagged).toBeUndefined();
    expect(body.crisis_resources).toBeDefined();
    expect(body.crisis_resources!.crisis_card_url).toBe('/crisis');
    expect(body.crisis_resources!.hotlines.length).toBeGreaterThan(0);
    // Persisted alongside the row so the moderation queue can sort
    // by triage signal later.
    const db = drizzle(env.FORUM_DB);
    const [row] = await db.select().from(posts).where(eq(posts.id, body.id));
    expect(row.crisisFlagged).toBe(true);
    expect(row.hidden).toBe(false);
    // The author's text is preserved verbatim — the banner is a
    // resource pointer, not a censor.
    expect(row.body).toContain('kill myself');
  });
});

// ---------- PATCH /api/v1/posts/:id ----------

describe('PATCH /api/v1/posts/:id', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts/some-id`, {
      method: 'PATCH',
    });
    expect(res.status).toBe(401);
  });

  it('returns 404 when the post does not exist', async () => {
    await makeProfile('cb-patch-missing');
    const res = await authedFetch('/api/v1/posts/does-not-exist', {
      method: 'PATCH',
      sub: 'cb-patch-missing',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: 'updated' }),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'post_not_found' });
  });

  it('returns 404 when the post is hidden', async () => {
    const author = await makeProfile('cb-patch-hidden');
    const hidden = await seedPost({
      authorId: author.id,
      title: 'gone',
      body: 'gone',
      hidden: true,
    });
    const res = await authedFetch(`/api/v1/posts/${hidden.id}`, {
      method: 'PATCH',
      sub: 'cb-patch-hidden',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: 'still trying' }),
    });
    expect(res.status).toBe(404);
  });

  it('returns 403 when the caller is not the author', async () => {
    const author = await makeProfile('cb-patch-owner');
    await makeProfile('cb-patch-stranger');
    const created = await seedPost({
      authorId: author.id,
      title: 'mine',
      body: 'body',
    });
    const res = await authedFetch(`/api/v1/posts/${created.id}`, {
      method: 'PATCH',
      sub: 'cb-patch-stranger',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: 'hijacked' }),
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: 'forbidden' });
  });

  it('returns 400 when the body field is missing or invalid', async () => {
    const author = await makeProfile('cb-patch-invalid');
    const created = await seedPost({
      authorId: author.id,
      title: 'mine',
      body: 'body',
    });
    const res = await authedFetch(`/api/v1/posts/${created.id}`, {
      method: 'PATCH',
      sub: 'cb-patch-invalid',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: '' }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_body_text' });
  });

  it('does NOT allow editing the title', async () => {
    const author = await makeProfile('cb-patch-title');
    const created = await seedPost({
      authorId: author.id,
      title: 'original title',
      body: 'original body',
    });
    const res = await authedFetch(`/api/v1/posts/${created.id}`, {
      method: 'PATCH',
      sub: 'cb-patch-title',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: 'new title', body: 'new body' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { title: string; body: string };
    expect(body.title).toBe('original title');
    expect(body.body).toBe('new body');
  });

  it('updates body and bumps updated_at', async () => {
    const author = await makeProfile('cb-patch-ok');
    // Back-date the post so updated_at strictly advances on patch.
    const earlier = new Date(Date.now() - 60_000);
    const created = await seedPost({
      authorId: author.id,
      title: 'mine',
      body: 'old body',
      createdAt: earlier,
    });
    const res = await authedFetch(`/api/v1/posts/${created.id}`, {
      method: 'PATCH',
      sub: 'cb-patch-ok',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: 'fresh body' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      body: string;
      created_at: string;
      updated_at: string;
    };
    expect(body.body).toBe('fresh body');
    expect(new Date(body.updated_at).getTime()).toBeGreaterThan(
      new Date(body.created_at).getTime(),
    );
  });
});

// ---------- DELETE /api/v1/posts/:id ----------

describe('DELETE /api/v1/posts/:id', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts/some-id`, {
      method: 'DELETE',
    });
    expect(res.status).toBe(401);
  });

  it('returns 404 for an unknown post', async () => {
    await makeProfile('cb-del-missing');
    const res = await authedFetch('/api/v1/posts/does-not-exist', {
      method: 'DELETE',
      sub: 'cb-del-missing',
    });
    expect(res.status).toBe(404);
  });

  it('returns 404 when the post is already hidden', async () => {
    const author = await makeProfile('cb-del-hidden');
    const hidden = await seedPost({
      authorId: author.id,
      title: 'gone',
      body: 'gone',
      hidden: true,
    });
    const res = await authedFetch(`/api/v1/posts/${hidden.id}`, {
      method: 'DELETE',
      sub: 'cb-del-hidden',
    });
    expect(res.status).toBe(404);
  });

  it('returns 403 for a non-author, non-admin caller', async () => {
    const author = await makeProfile('cb-del-owner');
    await makeProfile('cb-del-stranger');
    const created = await seedPost({
      authorId: author.id,
      title: 'mine',
      body: 'body',
    });
    const res = await authedFetch(`/api/v1/posts/${created.id}`, {
      method: 'DELETE',
      sub: 'cb-del-stranger',
    });
    expect(res.status).toBe(403);
  });

  it('lets the author soft-delete (hidden=true)', async () => {
    const author = await makeProfile('cb-del-author');
    const created = await seedPost({
      authorId: author.id,
      title: 'mine',
      body: 'body',
    });
    const res = await authedFetch(`/api/v1/posts/${created.id}`, {
      method: 'DELETE',
      sub: 'cb-del-author',
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ id: created.id, hidden: true });

    const db = drizzle(env.FORUM_DB);
    const [row] = await db.select().from(posts).where(eq(posts.id, created.id));
    expect(row.hidden).toBe(true);
  });

  it('lets an admin soft-delete a post they did not author', async () => {
    const author = await makeProfile('cb-del-victim');
    await makeProfile('cb-del-admin', { role: 'admin' });
    const created = await seedPost({
      authorId: author.id,
      title: 'flagged',
      body: 'body',
    });
    const res = await authedFetch(`/api/v1/posts/${created.id}`, {
      method: 'DELETE',
      sub: 'cb-del-admin',
    });
    expect(res.status).toBe(200);

    const db = drizzle(env.FORUM_DB);
    const [row] = await db.select().from(posts).where(eq(posts.id, created.id));
    expect(row.hidden).toBe(true);
  });

  it('after delete, the post stops appearing in the feed and /:id', async () => {
    const author = await makeProfile('cb-del-vanish');
    const created = await seedPost({
      authorId: author.id,
      title: 'vanishing',
      body: 'body',
    });
    await authedFetch(`/api/v1/posts/${created.id}`, {
      method: 'DELETE',
      sub: 'cb-del-vanish',
    });

    const feedRes = await SELF.fetch(`${ORIGIN}/api/v1/posts`);
    const feed = (await feedRes.json()) as { posts: unknown[] };
    expect(feed.posts).toHaveLength(0);

    const detailRes = await SELF.fetch(`${ORIGIN}/api/v1/posts/${created.id}`);
    expect(detailRes.status).toBe(404);
  });
});

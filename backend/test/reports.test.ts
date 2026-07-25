import { SELF, env } from 'cloudflare:test';
import { eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

import {
  comments,
  posts,
  profiles,
  reports,
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
  options: { role?: 'user' | 'admin' | 'banned'; displayName?: string } = {},
): Promise<Profile> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db
    .insert(profiles)
    .values({
      displayName: options.displayName ?? sub,
      holdcloseUserId: sub,
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
}): Promise<Comment> {
  const db = drizzle(env.FORUM_DB);
  const [row] = await db
    .insert(comments)
    .values({
      postId: values.postId,
      authorId: values.authorId,
      body: values.body ?? 'comment',
    })
    .returning();
  return row;
}

beforeEach(async () => {
  await clearTables();
});

// ---------- POST /api/v1/reports ----------

describe('POST /api/v1/reports', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/reports`, {
      method: 'POST',
    });
    expect(res.status).toBe(401);
  });

  it('returns 404 when the reporter has no profile', async () => {
    const res = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-no-profile',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: 'whatever',
        reason: 'spam',
      }),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it('returns 400 when the body is not JSON', async () => {
    await makeProfile('cb-report-bad-json');
    const res = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-bad-json',
      headers: { 'Content-Type': 'application/json' },
      body: 'not-json',
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_body' });
  });

  it('returns 400 on an invalid target_kind', async () => {
    await makeProfile('cb-report-bad-kind');
    const res = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-bad-kind',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'photo',
        target_id: 'x',
        reason: 'spam',
      }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_target_kind' });
  });

  it('returns 400 when target_id is empty', async () => {
    await makeProfile('cb-report-bad-tid');
    const res = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-bad-tid',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: '',
        reason: 'spam',
      }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_target_id' });
  });

  it.each([
    ['', 'empty'],
    ['x'.repeat(501), 'over 500 chars'],
  ])('returns 400 when reason is %j (%s)', async (reason) => {
    const author = await makeProfile('cb-report-bad-reason');
    const post = await seedPost({ authorId: author.id });
    const res = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-bad-reason',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: post.id,
        reason,
      }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_reason' });
  });

  it('returns 404 when the post target does not exist', async () => {
    await makeProfile('cb-report-missing-post');
    const res = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-missing-post',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: 'does-not-exist',
        reason: 'spam',
      }),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'target_not_found' });
  });

  it('returns 404 when the comment target does not exist', async () => {
    await makeProfile('cb-report-missing-cmt');
    const res = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-missing-cmt',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'comment',
        target_id: 'does-not-exist',
        reason: 'spam',
      }),
    });
    expect(res.status).toBe(404);
  });

  it('creates a pending post report and persists it', async () => {
    const author = await makeProfile('cb-report-author');
    const reporter = await makeProfile('cb-report-reporter');
    const post = await seedPost({ authorId: author.id });

    const res = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-reporter',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: post.id,
        reason: 'spam — promo for some pill',
      }),
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      target_kind: 'post',
      target_id: post.id,
      reporter_id: reporter.id,
      reason: 'spam — promo for some pill',
      status: 'pending',
      resolved_at: null,
    });

    const db = drizzle(env.FORUM_DB);
    const rows = await db.select().from(reports);
    expect(rows).toHaveLength(1);
  });

  it('accepts reports against already-hidden targets', async () => {
    const author = await makeProfile('cb-report-hidden-author');
    await makeProfile('cb-report-hidden-reporter');
    const post = await seedPost({ authorId: author.id, hidden: true });

    const res = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-hidden-reporter',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: post.id,
        reason: 'already gone but I want to escalate',
      }),
    });
    expect(res.status).toBe(201);
  });

  it('returns the existing OPEN report (200, no new row) when the same '
      + 'reporter re-files against the same target', async () => {
    const author = await makeProfile('cb-report-dup-author');
    await makeProfile('cb-report-dup-reporter');
    const post = await seedPost({ authorId: author.id });

    const first = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-dup-reporter',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: post.id,
        reason: 'report #0',
      }),
    });
    expect(first.status).toBe(201);
    const firstBody = (await first.json()) as { id: string; reason: string };

    const second = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-dup-reporter',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: post.id,
        reason: 'report #1',
      }),
    });
    expect(second.status).toBe(200);
    const secondBody = (await second.json()) as {
      id: string;
      reason: string;
      status: string;
    };
    // Same row comes back — original reason intact, still pending.
    expect(secondBody.id).toBe(firstBody.id);
    expect(secondBody.reason).toBe('report #0');
    expect(secondBody.status).toBe('pending');

    const db = drizzle(env.FORUM_DB);
    const rows = await db.select().from(reports);
    expect(rows).toHaveLength(1);
  });

  it('a DIFFERENT reporter against the same target still files a fresh '
      + 'row (volume stays a triage signal)', async () => {
    const author = await makeProfile('cb-report-vol-author');
    await makeProfile('cb-report-vol-r1');
    await makeProfile('cb-report-vol-r2');
    const post = await seedPost({ authorId: author.id });

    for (const sub of ['cb-report-vol-r1', 'cb-report-vol-r2']) {
      const res = await authedFetch('/api/v1/reports', {
        method: 'POST',
        sub,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          target_kind: 'post',
          target_id: post.id,
          reason: 'spam',
        }),
      });
      expect(res.status).toBe(201);
    }
    const db = drizzle(env.FORUM_DB);
    const rows = await db.select().from(reports);
    expect(rows).toHaveLength(2);
  });

  it('allows a fresh report once the earlier one is resolved '
      + '(reviewed via the moderation flow)', async () => {
    const author = await makeProfile('cb-report-refile-author');
    await makeProfile('cb-report-refile-reporter');
    await makeProfile('cb-report-refile-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });

    const first = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-refile-reporter',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: post.id,
        reason: 'first complaint',
      }),
    });
    expect(first.status).toBe(201);
    const { id: firstId } = (await first.json()) as { id: string };

    // Admin reviews it (no_action → status: reviewed).
    const reviewed = await authedFetch(`/api/v1/reports/${firstId}`, {
      method: 'PATCH',
      sub: 'cb-report-refile-admin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'no_action' }),
    });
    expect(reviewed.status).toBe(200);

    // The same reporter re-flagging the same target now lands a NEW row.
    const refiled = await authedFetch('/api/v1/reports', {
      method: 'POST',
      sub: 'cb-report-refile-reporter',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target_kind: 'post',
        target_id: post.id,
        reason: 'it happened again',
      }),
    });
    expect(refiled.status).toBe(201);
    const refiledBody = (await refiled.json()) as { id: string };
    expect(refiledBody.id).not.toBe(firstId);

    const db = drizzle(env.FORUM_DB);
    const rows = await db.select().from(reports);
    expect(rows).toHaveLength(2);
  });
});

// ---------- GET /api/v1/reports ----------

describe('GET /api/v1/reports', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/reports`);
    expect(res.status).toBe(401);
  });

  it('returns 403 for a non-admin caller', async () => {
    await makeProfile('cb-report-list-user');
    const res = await authedFetch('/api/v1/reports', {
      method: 'GET',
      sub: 'cb-report-list-user',
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: 'forbidden' });
  });

  it('returns 400 on an invalid status filter', async () => {
    await makeProfile('cb-report-list-admin', { role: 'admin' });
    const res = await authedFetch('/api/v1/reports?status=potato', {
      method: 'GET',
      sub: 'cb-report-list-admin',
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_status' });
  });

  it('returns pending reports newest-first by default', async () => {
    const author = await makeProfile('cb-report-list-author');
    const reporter = await makeProfile('cb-report-list-reporter');
    await makeProfile('cb-report-list-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });

    const db = drizzle(env.FORUM_DB);
    const base = Date.now();
    await db.insert(reports).values([
      {
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'older',
        createdAt: new Date(base - 60_000),
      },
      {
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'newer',
        createdAt: new Date(base),
      },
      {
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'already-handled',
        status: 'actioned',
        createdAt: new Date(base - 30_000),
      },
    ]);

    const res = await authedFetch('/api/v1/reports', {
      method: 'GET',
      sub: 'cb-report-list-admin',
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      reports: { reason: string; status: string }[];
    };
    expect(body.reports.map((r) => r.reason)).toEqual(['newer', 'older']);
    expect(body.reports.every((r) => r.status === 'pending')).toBe(true);
  });

  it('honors ?status=actioned', async () => {
    const author = await makeProfile('cb-rl-author');
    const reporter = await makeProfile('cb-rl-reporter');
    await makeProfile('cb-rl-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });

    const db = drizzle(env.FORUM_DB);
    await db.insert(reports).values([
      {
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'pending one',
      },
      {
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'actioned one',
        status: 'actioned',
      },
    ]);

    const res = await authedFetch('/api/v1/reports?status=actioned', {
      method: 'GET',
      sub: 'cb-rl-admin',
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { reports: { reason: string }[] };
    expect(body.reports.map((r) => r.reason)).toEqual(['actioned one']);
  });
});

// ---------- PATCH /api/v1/reports/:id ----------

describe('PATCH /api/v1/reports/:id', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/reports/some-id`, {
      method: 'PATCH',
    });
    expect(res.status).toBe(401);
  });

  it('returns 403 for a non-admin caller', async () => {
    await makeProfile('cb-rp-user');
    const res = await authedFetch('/api/v1/reports/whatever', {
      method: 'PATCH',
      sub: 'cb-rp-user',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'no_action' }),
    });
    expect(res.status).toBe(403);
  });

  it('returns 404 when the report does not exist', async () => {
    await makeProfile('cb-rp-admin', { role: 'admin' });
    const res = await authedFetch('/api/v1/reports/missing-id', {
      method: 'PATCH',
      sub: 'cb-rp-admin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'no_action' }),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'report_not_found' });
  });

  it('returns 400 on an invalid action', async () => {
    const author = await makeProfile('cb-rp-author');
    const reporter = await makeProfile('cb-rp-reporter');
    await makeProfile('cb-rp-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });
    const db = drizzle(env.FORUM_DB);
    const [report] = await db
      .insert(reports)
      .values({
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'spam',
      })
      .returning();

    const res = await authedFetch(`/api/v1/reports/${report.id}`, {
      method: 'PATCH',
      sub: 'cb-rp-admin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'nuke_from_orbit' }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_action' });
  });

  it('returns 409 when the report is already resolved', async () => {
    const author = await makeProfile('cb-rp-done-author');
    const reporter = await makeProfile('cb-rp-done-reporter');
    await makeProfile('cb-rp-done-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });
    const db = drizzle(env.FORUM_DB);
    const [report] = await db
      .insert(reports)
      .values({
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'spam',
        status: 'reviewed',
      })
      .returning();

    const res = await authedFetch(`/api/v1/reports/${report.id}`, {
      method: 'PATCH',
      sub: 'cb-rp-done-admin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'no_action' }),
    });
    expect(res.status).toBe(409);
  });

  it('no_action marks reviewed without hiding the target', async () => {
    const author = await makeProfile('cb-rp-na-author');
    const reporter = await makeProfile('cb-rp-na-reporter');
    await makeProfile('cb-rp-na-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });
    const db = drizzle(env.FORUM_DB);
    const [report] = await db
      .insert(reports)
      .values({
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'maybe spam',
      })
      .returning();

    const res = await authedFetch(`/api/v1/reports/${report.id}`, {
      method: 'PATCH',
      sub: 'cb-rp-na-admin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'no_action' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      status: 'reviewed',
      action: 'no_action',
      banned_user_id: null,
    });
    expect(body.resolved_at).toBeTruthy();

    const [postRow] = await db.select().from(posts).where(eq(posts.id, post.id));
    expect(postRow.hidden).toBe(false);
  });

  it('hide_target hides a reported post and marks actioned', async () => {
    const author = await makeProfile('cb-rp-h-author');
    const reporter = await makeProfile('cb-rp-h-reporter');
    await makeProfile('cb-rp-h-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });
    const db = drizzle(env.FORUM_DB);
    const [report] = await db
      .insert(reports)
      .values({
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'graphic',
      })
      .returning();

    const res = await authedFetch(`/api/v1/reports/${report.id}`, {
      method: 'PATCH',
      sub: 'cb-rp-h-admin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'hide_target' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      status: 'actioned',
      action: 'hide_target',
      banned_user_id: null,
    });

    const [postRow] = await db.select().from(posts).where(eq(posts.id, post.id));
    expect(postRow.hidden).toBe(true);

    const [authorRow] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.id, author.id));
    expect(authorRow.role).toBe('user');
  });

  it('hide_target also works for comments', async () => {
    const author = await makeProfile('cb-rp-hc-author');
    const reporter = await makeProfile('cb-rp-hc-reporter');
    await makeProfile('cb-rp-hc-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });
    const cmt = await seedComment({ postId: post.id, authorId: author.id });
    const db = drizzle(env.FORUM_DB);
    const [report] = await db
      .insert(reports)
      .values({
        targetKind: 'comment',
        targetId: cmt.id,
        reporterId: reporter.id,
        reason: 'rude',
      })
      .returning();

    const res = await authedFetch(`/api/v1/reports/${report.id}`, {
      method: 'PATCH',
      sub: 'cb-rp-hc-admin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'hide_target' }),
    });
    expect(res.status).toBe(200);

    const [cmtRow] = await db
      .select()
      .from(comments)
      .where(eq(comments.id, cmt.id));
    expect(cmtRow.hidden).toBe(true);
  });

  it('ban_user hides the target AND flips the author role to banned', async () => {
    const author = await makeProfile('cb-rp-b-author');
    const reporter = await makeProfile('cb-rp-b-reporter');
    await makeProfile('cb-rp-b-admin', { role: 'admin' });
    const post = await seedPost({ authorId: author.id });
    const db = drizzle(env.FORUM_DB);
    const [report] = await db
      .insert(reports)
      .values({
        targetKind: 'post',
        targetId: post.id,
        reporterId: reporter.id,
        reason: 'sales spam x10',
      })
      .returning();

    const res = await authedFetch(`/api/v1/reports/${report.id}`, {
      method: 'PATCH',
      sub: 'cb-rp-b-admin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'ban_user' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { banned_user_id: string | null };
    expect(body.banned_user_id).toBe(author.id);

    const [postRow] = await db.select().from(posts).where(eq(posts.id, post.id));
    expect(postRow.hidden).toBe(true);

    const [authorRow] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.id, author.id));
    expect(authorRow.role).toBe('banned');
  });
});

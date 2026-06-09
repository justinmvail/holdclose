import { SELF, env } from 'cloudflare:test';
import { drizzle } from 'drizzle-orm/d1';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

import { comments, posts, profiles } from '../src/db/schema';

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

beforeEach(async () => {
  await clearTables();
});

describe('POST /api/v1/profiles/bootstrap', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/bootstrap`, {
      method: 'POST',
    });
    expect(res.status).toBe(401);
  });

  it('creates a profile with a Caregiver_<6 hex> default name on first call', async () => {
    const res = await authedFetch('/api/v1/profiles/bootstrap', {
      method: 'POST',
      sub: 'cb-user-1',
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.careblazers_user_id).toBe('cb-user-1');
    expect(body.role).toBe('user');
    expect(body.avatar_url).toBeNull();
    expect(typeof body.display_name).toBe('string');
    expect(body.display_name).toMatch(/^Caregiver_[0-9a-f]{6}$/);
    expect(typeof body.joined_at).toBe('string');
    expect(typeof body.id).toBe('string');
  });

  it('is deterministic: same user gets the same default display_name', async () => {
    const first = (await (
      await authedFetch('/api/v1/profiles/bootstrap', {
        method: 'POST',
        sub: 'cb-user-deterministic',
      })
    ).json()) as { display_name: string };

    await clearTables();

    const second = (await (
      await authedFetch('/api/v1/profiles/bootstrap', {
        method: 'POST',
        sub: 'cb-user-deterministic',
      })
    ).json()) as { display_name: string };

    expect(second.display_name).toBe(first.display_name);
  });

  it('is idempotent — second call returns 200 + the same profile', async () => {
    const first = await authedFetch('/api/v1/profiles/bootstrap', {
      method: 'POST',
      sub: 'cb-user-idem',
    });
    expect(first.status).toBe(201);
    const firstBody = (await first.json()) as { id: string };

    const second = await authedFetch('/api/v1/profiles/bootstrap', {
      method: 'POST',
      sub: 'cb-user-idem',
    });
    expect(second.status).toBe(200);
    const secondBody = (await second.json()) as { id: string };
    expect(secondBody.id).toBe(firstBody.id);

    const rows = await drizzle(env.FORUM_DB).select().from(profiles);
    expect(rows).toHaveLength(1);
  });
});

describe('GET /api/v1/profiles/me', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/me`);
    expect(res.status).toBe(401);
  });

  it('returns 404 before the user has bootstrapped', async () => {
    const res = await authedFetch('/api/v1/profiles/me', { sub: 'cb-user-no-profile' });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it('returns the current user’s profile after bootstrap', async () => {
    const created = (await (
      await authedFetch('/api/v1/profiles/bootstrap', {
        method: 'POST',
        sub: 'cb-user-me',
      })
    ).json()) as { id: string; display_name: string };

    const res = await authedFetch('/api/v1/profiles/me', { sub: 'cb-user-me' });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string; display_name: string };
    expect(body.id).toBe(created.id);
    expect(body.display_name).toBe(created.display_name);
  });
});

describe('PATCH /api/v1/profiles/me', () => {
  beforeEach(async () => {
    await authedFetch('/api/v1/profiles/bootstrap', {
      method: 'POST',
      sub: 'cb-user-patch',
    });
  });

  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/me`, {
      method: 'PATCH',
    });
    expect(res.status).toBe(401);
  });

  it('returns 400 when the body is not JSON', async () => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-patch',
      headers: { 'Content-Type': 'application/json' },
      body: 'not-json',
    });
    expect(res.status).toBe(400);
  });

  it('returns 400 when no updatable fields are provided', async () => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-patch',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'no_fields_to_update' });
  });

  it('updates display_name on a valid value', async () => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-patch',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ display_name: 'sundown_sally' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { display_name: string };
    expect(body.display_name).toBe('sundown_sally');
  });

  it.each([
    ['ab', 'too short'],
    ['a'.repeat(31), 'too long'],
    ['has space', 'space not allowed'],
    ['emoji_💀_name', 'unicode not allowed'],
    ['dash-not-ok', 'dash not allowed'],
  ])('rejects display_name %j (%s)', async (displayName) => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-patch',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ display_name: displayName }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_display_name' });
  });

  it('rejects display_name flagged by the profanity wordlist', async () => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-patch',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ display_name: 'MegaShit99' }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'profanity_blocked' });
  });

  it('accepts an avatar_url that starts with the project R2 origin', async () => {
    const avatar = `${env.R2_PUBLIC_URL}/avatars/cb-user-patch.jpg`;
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-patch',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ avatar_url: avatar }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { avatar_url: string };
    expect(body.avatar_url).toBe(avatar);
  });

  it('rejects an avatar_url whose origin is not R2', async () => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-patch',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ avatar_url: 'https://i.imgur.com/evil.png' }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_avatar_url' });
  });

  it('updates both display_name and avatar_url in one call', async () => {
    const avatar = `${env.R2_PUBLIC_URL}/avatars/combo.jpg`;
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-patch',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        display_name: 'combo_user',
        avatar_url: avatar,
      }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      display_name: string;
      avatar_url: string;
    };
    expect(body.display_name).toBe('combo_user');
    expect(body.avatar_url).toBe(avatar);
  });

  it('returns 404 when the authed user has no profile yet', async () => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-no-profile-patch',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ display_name: 'never_made_it' }),
    });
    expect(res.status).toBe(404);
  });
});

describe('GET /api/v1/profiles/username-available', () => {
  beforeEach(async () => {
    await authedFetch('/api/v1/profiles/bootstrap', {
      method: 'POST',
      sub: 'cb-user-avail',
    });
  });

  it('returns valid:false available:false for a pattern-invalid handle', async () => {
    const res = await authedFetch('/api/v1/profiles/username-available?u=ab', {
      sub: 'cb-user-avail',
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ valid: false, available: false });
  });

  it('returns valid:false for an uppercase handle (lowercase-only pattern)', async () => {
    const res = await authedFetch(
      '/api/v1/profiles/username-available?u=NotLower',
      { sub: 'cb-user-avail' },
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ valid: false, available: false });
  });

  it('returns valid:false for a profane handle', async () => {
    const res = await authedFetch(
      '/api/v1/profiles/username-available?u=shithead',
      { sub: 'cb-user-avail' },
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ valid: false, available: false });
  });

  it('returns valid:true available:true for an unused valid handle', async () => {
    const res = await authedFetch(
      '/api/v1/profiles/username-available?u=open_handle',
      { sub: 'cb-user-avail' },
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ valid: true, available: true });
  });

  it('returns available:false once another profile owns the handle', async () => {
    await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-avail',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'taken_one' }),
    });
    const res = await authedFetch(
      '/api/v1/profiles/username-available?u=taken_one',
      { sub: 'cb-user-avail' },
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ valid: true, available: false });
  });
});

describe('PATCH /api/v1/profiles/me — username', () => {
  beforeEach(async () => {
    await authedFetch('/api/v1/profiles/bootstrap', {
      method: 'POST',
      sub: 'cb-user-uname',
    });
  });

  it('sets a valid username (stored lowercased)', async () => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'caregiver_42' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { username: string };
    expect(body.username).toBe('caregiver_42');
  });

  it.each([
    ['ab', 'too short'],
    ['a'.repeat(21), 'too long'],
    ['Upper_Case', 'uppercase not allowed'],
    ['has space', 'space not allowed'],
    ['dash-no', 'dash not allowed'],
  ])('rejects username %j (%s) with 400', async (username) => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_username' });
  });

  it('rejects a profane username', async () => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'bitch_boss' }),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'profanity_blocked' });
  });

  it('returns 409 username_taken when another profile owns it', async () => {
    await authedFetch('/api/v1/profiles/bootstrap', {
      method: 'POST',
      sub: 'cb-user-uname-other',
    });
    await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname-other',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'shared_handle' }),
    });

    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'shared_handle' }),
    });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'username_taken' });
  });

  it('mirrors the username into display_name when it is still the default', async () => {
    const before = (await (
      await authedFetch('/api/v1/profiles/me', { sub: 'cb-user-uname' })
    ).json()) as { display_name: string };
    // Fresh bootstrap → display_name is the auto-generated Caregiver_<hex>.
    expect(before.display_name).toMatch(/^Caregiver_[0-9a-f]{6}$/);

    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'sarah_h' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      username: string;
      display_name: string;
    };
    expect(body.username).toBe('sarah_h');
    // Username is the canonical identity: the default display_name is
    // overwritten so every display surface shows the chosen handle.
    expect(body.display_name).toBe('sarah_h');
  });

  it('leaves a customized display_name untouched when setting a username', async () => {
    // The caregiver explicitly customized their display_name first.
    await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ display_name: 'Sarah_TG' }),
    });

    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'sarah_h' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      username: string;
      display_name: string;
    };
    expect(body.username).toBe('sarah_h');
    // A display_name that does NOT match the default pattern is preserved.
    expect(body.display_name).toBe('Sarah_TG');
  });

  it('lets the same user re-set their own username (no false 409)', async () => {
    await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'mine_now' }),
    });
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-uname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'mine_now' }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { username: string };
    expect(body.username).toBe('mine_now');
  });
});

describe('GET /api/v1/profiles/by-username/:username', () => {
  it('returns 404 when no profile owns the handle', async () => {
    const res = await authedFetch('/api/v1/profiles/by-username/ghost_user', {
      sub: 'cb-user-byname-viewer',
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it('returns the public username shape for a hit (case-insensitive lookup)', async () => {
    const created = (await (
      await authedFetch('/api/v1/profiles/bootstrap', {
        method: 'POST',
        sub: 'cb-user-byname',
      })
    ).json()) as { id: string; display_name: string };
    await authedFetch('/api/v1/profiles/me', {
      method: 'PATCH',
      sub: 'cb-user-byname',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'findable' }),
    });

    const res = await authedFetch('/api/v1/profiles/by-username/FINDABLE', {
      sub: 'cb-user-byname-viewer',
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    // Setting a username on a still-default profile mirrors it into
    // display_name (username is the canonical public identity), so the
    // public lookup surfaces the handle as the display name too.
    expect(body).toEqual({
      id: created.id,
      username: 'findable',
      display_name: 'findable',
      avatar_url: null,
    });
    expect(body).not.toHaveProperty('careblazers_user_id');
    expect(body).not.toHaveProperty('role');
  });
});

describe('GET /api/v1/profiles/:id', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/abc-123`);
    expect(res.status).toBe(401);
  });

  it('returns 404 for an unknown profile id', async () => {
    const res = await authedFetch('/api/v1/profiles/00000000-0000-0000-0000-000000000000', {
      sub: 'cb-user-lookup',
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it('returns the public profile shape with post + comment counts', async () => {
    const bootstrap = (await (
      await authedFetch('/api/v1/profiles/bootstrap', {
        method: 'POST',
        sub: 'cb-user-public',
      })
    ).json()) as { id: string; display_name: string };

    const db = drizzle(env.FORUM_DB);
    await db.insert(posts).values([
      {
        authorId: bootstrap.id,
        title: 'Sundowning tips?',
        body: 'looking for help in the evenings',
      },
      {
        authorId: bootstrap.id,
        title: 'Refusing to eat',
        body: 'mom won’t touch dinner',
      },
      // Hidden post — should not be counted.
      {
        authorId: bootstrap.id,
        title: 'hidden',
        body: 'hidden',
        hidden: true,
      },
    ]);

    const [aPost] = await db
      .insert(posts)
      .values({
        authorId: bootstrap.id,
        title: 'another',
        body: 'host post for comments',
      })
      .returning();
    await db.insert(comments).values([
      { postId: aPost.id, authorId: bootstrap.id, body: 'first' },
      { postId: aPost.id, authorId: bootstrap.id, body: 'second' },
      // Hidden comment — should not be counted.
      {
        postId: aPost.id,
        authorId: bootstrap.id,
        body: 'gone',
        hidden: true,
      },
    ]);

    const res = await authedFetch(`/api/v1/profiles/${bootstrap.id}`, {
      sub: 'cb-user-public-viewer',
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      id: bootstrap.id,
      display_name: bootstrap.display_name,
      avatar_url: null,
      post_count: 3,
      comment_count: 2,
    });
    expect(typeof body.joined_at).toBe('string');
    // Public payload must not leak careblazers_user_id or role.
    expect(body).not.toHaveProperty('careblazers_user_id');
    expect(body).not.toHaveProperty('role');
  });
});

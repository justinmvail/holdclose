import { SELF, env } from 'cloudflare:test';
import { drizzle } from 'drizzle-orm/d1';
import { eq, sql } from 'drizzle-orm';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

import { circleMembers, circleInvites, profiles } from '../src/db/schema';

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
    env.FORUM_DB.prepare('DELETE FROM care_docs'),
    env.FORUM_DB.prepare('DELETE FROM patients'),
    env.FORUM_DB.prepare('DELETE FROM circle_invites'),
    env.FORUM_DB.prepare('DELETE FROM circle_members'),
    env.FORUM_DB.prepare('DELETE FROM circles'),
    env.FORUM_DB.prepare('DELETE FROM profiles'),
  ]);
}

async function bootstrap(sub: string) {
  return (await (
    await authedFetch('/api/v1/profiles/bootstrap', { method: 'POST', sub })
  ).json()) as { id: string };
}

beforeEach(async () => {
  await clearTables();
});

describe('POST /api/v1/circles', () => {
  it('returns 401 without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/circles`, {
      method: 'POST',
    });
    expect(res.status).toBe(401);
  });

  it('returns 404 when the caller has no profile', async () => {
    const res = await authedFetch('/api/v1/circles', {
      method: 'POST',
      sub: 'cb-no-profile',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: 'My Circle' }),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it.each([['', 'empty'], ['x'.repeat(61), 'too long']])(
    'rejects name %j (%s)',
    async (name) => {
      await bootstrap('cb-owner-bad');
      const res = await authedFetch('/api/v1/circles', {
        method: 'POST',
        sub: 'cb-owner-bad',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name }),
      });
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: 'invalid_name' });
    },
  );

  it('creates a circle and adds the caller as owner member', async () => {
    const owner = await bootstrap('cb-owner');
    const res = await authedFetch('/api/v1/circles', {
      method: 'POST',
      sub: 'cb-owner',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: "Mary's Care Team" }),
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as Record<string, any>;
    expect(typeof body.id).toBe('string');
    expect(body.name).toBe("Mary's Care Team");
    expect(body.owner_profile_id).toBe(owner.id);
    expect(typeof body.created_at).toBe('string');
    expect(body.members).toHaveLength(1);
    expect(body.members[0]).toMatchObject({
      profile_id: owner.id,
      role: 'owner',
      username: null,
    });
    // A minimal loved one is created with the circle and gets rev 1.
    expect(body.patient).toMatchObject({
      payload: '{}',
      rev: 1,
      deleted: false,
    });
    expect(typeof body.patient.client_updated_at).toBe('number');
  });

  it('seeds the loved one from an optional patient field', async () => {
    await bootstrap('cb-owner-patient');
    const res = await authedFetch('/api/v1/circles', {
      method: 'POST',
      sub: 'cb-owner-patient',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: 'Mary',
        patient: {
          payload: JSON.stringify({ name: 'Mary Henderson' }),
          client_updated_at: 1700000000000,
        },
      }),
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as Record<string, any>;
    expect(body.patient).toMatchObject({
      payload: JSON.stringify({ name: 'Mary Henderson' }),
      client_updated_at: 1700000000000,
      rev: 1,
      deleted: false,
    });
  });
});

describe('GET /api/v1/circles', () => {
  it('returns the empty list for a member of no circles', async () => {
    await bootstrap('cb-lonely');
    const res = await authedFetch('/api/v1/circles', { sub: 'cb-lonely' });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ circles: [] });
  });

  it('returns every circle the caller belongs to, with members', async () => {
    await bootstrap('cb-multi');
    const a = (await (
      await authedFetch('/api/v1/circles', {
        method: 'POST',
        sub: 'cb-multi',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'Circle A' }),
      })
    ).json()) as { id: string };
    await authedFetch('/api/v1/circles', {
      method: 'POST',
      sub: 'cb-multi',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: 'Circle B' }),
    });

    const res = await authedFetch('/api/v1/circles', { sub: 'cb-multi' });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { circles: any[] };
    expect(body.circles).toHaveLength(2);
    const found = body.circles.find((cc) => cc.id === a.id);
    expect(found.members).toHaveLength(1);
  });

  it('returns EVERY member of a multi-member circle — no member is '
      + 'dropped (leftJoin — 2026-06-14 roster bug)', async () => {
    // The real alpha bug: a joiner saw only the owner + herself; the person
    // who added her vanished because the old innerJoin dropped any
    // circle_members row whose profile didn't resolve. This is the
    // common-path regression guard — the full roster must come back.
    const owner = await bootstrap('cb-roster-owner');
    const circle = (await (
      await authedFetch('/api/v1/circles', {
        method: 'POST',
        sub: 'cb-roster-owner',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'Full roster' }),
      })
    ).json()) as { id: string };
    const invite = (await (
      await authedFetch(`/api/v1/circles/${circle.id}/invites`, {
        method: 'POST',
        sub: 'cb-roster-owner',
      })
    ).json()) as { token: string };
    const joiner = await bootstrap('cb-roster-joiner');
    await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-roster-joiner',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: invite.token }),
    });

    // The JOINER (the alpha user) lists circles and must see BOTH the owner
    // (who added her) and herself — not just herself + owner-only.
    const res = await authedFetch('/api/v1/circles', {
      sub: 'cb-roster-joiner',
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { circles: any[] };
    const found = body.circles.find((cc) => cc.id === circle.id);
    expect(found.members).toHaveLength(2);
    const ids = found.members.map((m: any) => m.profile_id).sort();
    expect(ids).toEqual([owner.id, joiner.id].sort());
  });

  it('maps a member whose profile does not resolve to the "[Member]" '
      + 'fallback (leftJoin keeps it; innerJoin would have dropped it)',
      async () => {
    // The TRUE orphan state — a circle_members row whose profile is gone —
    // can't be inserted through the route here because D1 enforces the
    // foreign key (and ignores PRAGMA foreign_keys=OFF), so we exercise
    // loadMembers' leftJoin + COALESCE at the query level: a left join that
    // resolves no profile row yields NULL profile columns, which the route
    // maps to display_name '[Member]' / username null. This pins the
    // fallback contract the production fix relies on.
    const owner = await bootstrap('cb-fallback-owner');
    const circle = (await (
      await authedFetch('/api/v1/circles', {
        method: 'POST',
        sub: 'cb-fallback-owner',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'Fallback' }),
      })
    ).json()) as { id: string };

    const db = drizzle(env.FORUM_DB);
    // Force the join to match no profile (0 = 1) so every membership row
    // comes back with NULL profile columns — the orphan shape.
    const rows = await db
      .select({
        profileId: circleMembers.profileId,
        role: circleMembers.role,
        username: profiles.username,
        displayName: profiles.displayName,
      })
      .from(circleMembers)
      .leftJoin(profiles, sql`0 = 1`)
      .where(eq(circleMembers.circleId, circle.id));
    // Apply the SAME mapping loadMembers() uses.
    const mapped = rows.map((r) => ({
      profile_id: r.profileId,
      username: r.username ?? null,
      display_name: r.displayName ?? '[Member]',
      role: r.role,
    }));
    expect(mapped).toHaveLength(1);
    expect(mapped[0]).toEqual({
      profile_id: owner.id,
      username: null,
      display_name: '[Member]',
      role: 'owner',
    });
  });
});

describe('POST /api/v1/circles/:id/invites', () => {
  it('returns 403 when the caller is not a member of the circle', async () => {
    await bootstrap('cb-inv-owner');
    const circle = (await (
      await authedFetch('/api/v1/circles', {
        method: 'POST',
        sub: 'cb-inv-owner',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'Private' }),
      })
    ).json()) as { id: string };

    await bootstrap('cb-inv-outsider');
    const res = await authedFetch(`/api/v1/circles/${circle.id}/invites`, {
      method: 'POST',
      sub: 'cb-inv-outsider',
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: 'forbidden' });
  });

  it('mints an invite token with a 48-hour expiry', async () => {
    await bootstrap('cb-inv-mint');
    const circle = (await (
      await authedFetch('/api/v1/circles', {
        method: 'POST',
        sub: 'cb-inv-mint',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'Invitable' }),
      })
    ).json()) as { id: string };

    const res = await authedFetch(`/api/v1/circles/${circle.id}/invites`, {
      method: 'POST',
      sub: 'cb-inv-mint',
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      token: string;
      circle_id: string;
      expires_at: string;
    };
    expect(typeof body.token).toBe('string');
    expect(body.circle_id).toBe(circle.id);
    const ttl = new Date(body.expires_at).getTime() - Date.now();
    // ~48h, allow generous slack for test timing.
    expect(ttl).toBeGreaterThan(47.5 * 60 * 60 * 1000);
    expect(ttl).toBeLessThan(48.5 * 60 * 60 * 1000);
  });
});

describe('POST /api/v1/circles/join', () => {
  async function ownerWithInvite() {
    const owner = await bootstrap('cb-join-owner');
    const circle = (await (
      await authedFetch('/api/v1/circles', {
        method: 'POST',
        sub: 'cb-join-owner',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'Joinable' }),
      })
    ).json()) as { id: string };
    const invite = (await (
      await authedFetch(`/api/v1/circles/${circle.id}/invites`, {
        method: 'POST',
        sub: 'cb-join-owner',
      })
    ).json()) as { token: string };
    return { owner, circle, token: invite.token };
  }

  it('returns 404 for an unknown token', async () => {
    await bootstrap('cb-join-user');
    const res = await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-user',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'does-not-exist' }),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'invite_not_found' });
  });

  it('adds a second user as a member and returns the circle', async () => {
    const { owner, circle, token } = await ownerWithInvite();
    const joiner = await bootstrap('cb-join-user');

    const res = await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-user',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string; members: any[] };
    expect(body.id).toBe(circle.id);
    expect(body.members).toHaveLength(2);
    const joinerMember = body.members.find((m) => m.profile_id === joiner.id);
    expect(joinerMember.role).toBe('member');
    expect(body.members.find((m) => m.profile_id === owner.id).role).toBe(
      'owner',
    );
  });

  it('is idempotent — re-joining does not duplicate membership', async () => {
    const { circle, token } = await ownerWithInvite();
    await bootstrap('cb-join-user');

    await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-user',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    const res = await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-user',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string; members: any[] };
    expect(body.id).toBe(circle.id);
    expect(body.members).toHaveLength(2);
  });

  it('returns 410 invite_expired for an expired invite', async () => {
    const { token } = await ownerWithInvite();
    await bootstrap('cb-join-user');

    const db = drizzle(env.FORUM_DB);
    await db
      .update(circleInvites)
      .set({ expiresAt: new Date(Date.now() - 1000) })
      .where(eq(circleInvites.token, token));

    const res = await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-user',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    expect(res.status).toBe(410);
    expect(await res.json()).toEqual({ error: 'invite_expired' });
  });

  it('returns 410 invite_expired for a revoked invite', async () => {
    const { token } = await ownerWithInvite();
    await bootstrap('cb-join-user');

    const db = drizzle(env.FORUM_DB);
    await db
      .update(circleInvites)
      .set({ revoked: true })
      .where(eq(circleInvites.token, token));

    const res = await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-user',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    expect(res.status).toBe(410);
    expect(await res.json()).toEqual({ error: 'invite_expired' });
  });

  it('invites are SINGLE-USE — a second (different) user gets 410 '
      + 'invite_used', async () => {
    const { token } = await ownerWithInvite();
    await bootstrap('cb-join-first');
    await bootstrap('cb-join-second');

    const first = await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-first',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    expect(first.status).toBe(200);

    const second = await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-second',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    expect(second.status).toBe(410);
    expect(await second.json()).toEqual({ error: 'invite_used' });
  });

  it('records the consumption (used_at + used_by) on join', async () => {
    const { token } = await ownerWithInvite();
    const joiner = await bootstrap('cb-join-consume');

    await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-consume',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });

    const db = drizzle(env.FORUM_DB);
    const [invite] = await db
      .select()
      .from(circleInvites)
      .where(eq(circleInvites.token, token));
    expect(invite.usedAt).not.toBeNull();
    expect(invite.usedByProfileId).toBe(joiner.id);
  });

  it('an EXISTING member re-tapping a consumed invite still gets the '
      + 'circle back (idempotent, not an error)', async () => {
    const { circle, token } = await ownerWithInvite();
    await bootstrap('cb-join-again');

    await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-again',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    // The invite is now consumed by this same user — re-redeeming must
    // short-circuit on the existing membership, not 410.
    const again = await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-join-again',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    expect(again.status).toBe(200);
    expect(((await again.json()) as { id: string }).id).toBe(circle.id);
  });
});

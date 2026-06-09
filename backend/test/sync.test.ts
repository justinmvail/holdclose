import { SELF, env } from 'cloudflare:test';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

const SECRET = env.FORUM_JWT_SECRET;
const ORIGIN = 'https://forum.careblazers.local';

const nowSec = () => Math.floor(Date.now() / 1000);

async function mintToken(sub: string) {
  const iat = nowSec();
  return sign({ sub, iat, exp: iat + 3600 }, SECRET, 'HS256');
}

async function authedFetch(path: string, init: RequestInit & { sub: string }) {
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

async function createCircle(sub: string, name = 'Care Team') {
  const res = await authedFetch('/api/v1/circles', {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name }),
  });
  return (await res.json()) as {
    id: string;
    patient: { payload: string; rev: number; deleted: boolean };
  };
}

async function mintInvite(sub: string, circleId: string) {
  const res = await authedFetch(`/api/v1/circles/${circleId}/invites`, {
    method: 'POST',
    sub,
  });
  return ((await res.json()) as { token: string }).token;
}

async function pull(sub: string, circleId: string, since?: number) {
  const q = since === undefined ? '' : `?since=${since}`;
  const res = await authedFetch(`/api/v1/sync/${circleId}${q}`, { sub });
  return {
    status: res.status,
    body: (await res.json()) as {
      cursor: number;
      patient: { payload: string; rev: number; deleted: boolean } | null;
      docs: {
        id: string;
        collection: string;
        payload: string;
        client_updated_at: number;
        rev: number;
        deleted: boolean;
      }[];
    },
  };
}

async function push(
  sub: string,
  circleId: string,
  body: Record<string, unknown>,
) {
  const res = await authedFetch(`/api/v1/sync/${circleId}`, {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return {
    status: res.status,
    body: (await res.json()) as {
      cursor: number;
      patient: { payload: string; rev: number; deleted: boolean } | null;
      applied: { id: string; rev: number; accepted: boolean }[];
    },
  };
}

beforeEach(async () => {
  await clearTables();
});

describe('GET /api/v1/sync/:circleId (pull)', () => {
  it('returns 403 for a non-member', async () => {
    await bootstrap('cb-pull-owner');
    const circle = await createCircle('cb-pull-owner');

    await bootstrap('cb-pull-outsider');
    const res = await authedFetch(`/api/v1/sync/${circle.id}`, {
      sub: 'cb-pull-outsider',
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: 'forbidden' });
  });

  it('returns 404 when the caller has no profile', async () => {
    const res = await authedFetch('/api/v1/sync/some-circle', {
      sub: 'cb-pull-noprofile',
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it('returns 404 for an unknown circle', async () => {
    await bootstrap('cb-pull-unknown');
    const res = await authedFetch('/api/v1/sync/does-not-exist', {
      sub: 'cb-pull-unknown',
    });
    expect(res.status).toBe(404);
  });

  it('full pull (since=0) returns the patient and no docs initially', async () => {
    await bootstrap('cb-full');
    const circle = await createCircle('cb-full');

    const { status, body } = await pull('cb-full', circle.id, 0);
    expect(status).toBe(200);
    expect(body.cursor).toBe(1); // patient consumed rev 1
    expect(body.patient).toMatchObject({ payload: '{}', rev: 1 });
    expect(body.docs).toEqual([]);
  });
});

describe('POST /api/v1/sync/:circleId (push)', () => {
  it('assigns increasing revs to new docs', async () => {
    await bootstrap('cb-push');
    const circle = await createCircle('cb-push');

    const { status, body } = await push('cb-push', circle.id, {
      docs: [
        {
          id: 'med-1',
          collection: 'medication',
          payload: '{"name":"Donepezil"}',
          client_updated_at: 1000,
        },
        {
          id: 'med-2',
          collection: 'medication',
          payload: '{"name":"Memantine"}',
          client_updated_at: 1001,
        },
      ],
    });
    expect(status).toBe(200);
    expect(body.applied).toHaveLength(2);
    expect(body.applied[0]).toMatchObject({ id: 'med-1', accepted: true });
    expect(body.applied[1]).toMatchObject({ id: 'med-2', accepted: true });
    // patient was rev 1, so docs get 2 and 3, cursor 3.
    expect(body.applied[0].rev).toBe(2);
    expect(body.applied[1].rev).toBe(3);
    expect(body.cursor).toBe(3);
  });

  it('rejects a stale write (older client_updated_at) and accepts a newer one', async () => {
    await bootstrap('cb-lww');
    const circle = await createCircle('cb-lww');

    await push('cb-lww', circle.id, {
      docs: [
        {
          id: 'task-1',
          collection: 'task',
          payload: '{"v":2}',
          client_updated_at: 2000,
        },
      ],
    });

    // Stale: older client_updated_at -> rejected, stored stays.
    const stale = await push('cb-lww', circle.id, {
      docs: [
        {
          id: 'task-1',
          collection: 'task',
          payload: '{"v":1}',
          client_updated_at: 1000,
        },
      ],
    });
    expect(stale.body.applied[0].accepted).toBe(false);

    const afterStale = await pull('cb-lww', circle.id, 0);
    const storedAfterStale = afterStale.body.docs.find((d) => d.id === 'task-1');
    expect(storedAfterStale?.payload).toBe('{"v":2}');

    // Newer: accepted, gets a fresh rev.
    const fresh = await push('cb-lww', circle.id, {
      docs: [
        {
          id: 'task-1',
          collection: 'task',
          payload: '{"v":3}',
          client_updated_at: 3000,
        },
      ],
    });
    expect(fresh.body.applied[0].accepted).toBe(true);

    const afterFresh = await pull('cb-lww', circle.id, 0);
    const storedAfterFresh = afterFresh.body.docs.find((d) => d.id === 'task-1');
    expect(storedAfterFresh?.payload).toBe('{"v":3}');
  });

  it('equal client_updated_at is accepted (>=)', async () => {
    await bootstrap('cb-eq');
    const circle = await createCircle('cb-eq');

    await push('cb-eq', circle.id, {
      docs: [
        { id: 'd1', collection: 'note', payload: 'a', client_updated_at: 500 },
      ],
    });
    const second = await push('cb-eq', circle.id, {
      docs: [
        { id: 'd1', collection: 'note', payload: 'b', client_updated_at: 500 },
      ],
    });
    expect(second.body.applied[0].accepted).toBe(true);
  });

  it('LWW-upserts the patient on push', async () => {
    await bootstrap('cb-ppush');
    const circle = await createCircle('cb-ppush');

    // Must beat the wall-clock client_updated_at of the auto-created patient.
    const res = await push('cb-ppush', circle.id, {
      patient: {
        payload: JSON.stringify({ name: 'Mary' }),
        client_updated_at: Date.now() + 60_000,
      },
      docs: [],
    });
    expect(res.body.patient).toMatchObject({
      payload: JSON.stringify({ name: 'Mary' }),
    });
    // patient rev advanced past the initial rev 1.
    expect(res.body.patient?.rev).toBeGreaterThan(1);

    // Stale patient write is ignored.
    const stale = await push('cb-ppush', circle.id, {
      patient: {
        payload: JSON.stringify({ name: 'OLD' }),
        client_updated_at: 1,
      },
      docs: [],
    });
    expect(stale.body.patient?.payload).toBe(JSON.stringify({ name: 'Mary' }));
  });

  it('returns 400 for a malformed body', async () => {
    await bootstrap('cb-bad');
    const circle = await createCircle('cb-bad');

    const res = await authedFetch(`/api/v1/sync/${circle.id}`, {
      method: 'POST',
      sub: 'cb-bad',
      headers: { 'Content-Type': 'application/json' },
      body: '{not json',
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'invalid_body' });
  });

  it('returns 400 for a doc missing required fields', async () => {
    await bootstrap('cb-baddoc');
    const circle = await createCircle('cb-baddoc');

    const res = await push('cb-baddoc', circle.id, {
      docs: [{ id: 'x', collection: 'task' }],
    });
    expect(res.status).toBe(400);
    expect(res.body as unknown).toEqual({ error: 'invalid_body' });
  });

  it('returns 400 when the batch exceeds 500 docs', async () => {
    await bootstrap('cb-cap');
    const circle = await createCircle('cb-cap');

    const docs = Array.from({ length: 501 }, (_, i) => ({
      id: `d${i}`,
      collection: 'task',
      payload: '{}',
      client_updated_at: i,
    }));
    const res = await push('cb-cap', circle.id, { docs });
    expect(res.status).toBe(400);
  });

  it('returns 403 for a non-member push', async () => {
    await bootstrap('cb-pushowner');
    const circle = await createCircle('cb-pushowner');
    await bootstrap('cb-pushoutsider');

    const res = await push('cb-pushoutsider', circle.id, { docs: [] });
    expect(res.status).toBe(403);
  });
});

describe('delta pull semantics', () => {
  it('returns only docs newer than the cursor', async () => {
    await bootstrap('cb-delta');
    const circle = await createCircle('cb-delta');

    const first = await push('cb-delta', circle.id, {
      docs: [
        { id: 'a', collection: 'task', payload: '1', client_updated_at: 10 },
      ],
    });
    const cursor = first.body.cursor;

    await push('cb-delta', circle.id, {
      docs: [
        { id: 'b', collection: 'task', payload: '2', client_updated_at: 20 },
      ],
    });

    const delta = await pull('cb-delta', circle.id, cursor);
    expect(delta.body.docs.map((d) => d.id)).toEqual(['b']);
    // Patient (rev 1) is older than the cursor, so it's null.
    expect(delta.body.patient).toBeNull();
  });

  it('propagates tombstones (deleted=true) on pull', async () => {
    await bootstrap('cb-tomb');
    const circle = await createCircle('cb-tomb');

    await push('cb-tomb', circle.id, {
      docs: [
        { id: 'gone', collection: 'task', payload: '{}', client_updated_at: 1 },
      ],
    });
    const del = await push('cb-tomb', circle.id, {
      docs: [
        {
          id: 'gone',
          collection: 'task',
          payload: '{}',
          client_updated_at: 2,
          deleted: true,
        },
      ],
    });
    const cursor = del.body.cursor;

    const full = await pull('cb-tomb', circle.id, 0);
    const tomb = full.body.docs.find((d) => d.id === 'gone');
    expect(tomb?.deleted).toBe(true);

    // Delta pull from before the delete also surfaces the tombstone.
    const delta = await pull('cb-tomb', circle.id, cursor - 1);
    expect(delta.body.docs.find((d) => d.id === 'gone')?.deleted).toBe(true);
  });

  it('keeps the cursor monotonic across pushes', async () => {
    await bootstrap('cb-mono');
    const circle = await createCircle('cb-mono');

    let prev = 0;
    for (let i = 0; i < 4; i++) {
      const r = await push('cb-mono', circle.id, {
        docs: [
          {
            id: `m${i}`,
            collection: 'task',
            payload: '{}',
            client_updated_at: i,
          },
        ],
      });
      expect(r.body.cursor).toBeGreaterThan(prev);
      prev = r.body.cursor;
    }
  });
});

describe('two members sharing care data', () => {
  it('member B pushes, member A pulls and sees B’s docs', async () => {
    await bootstrap('cb-a');
    const circle = await createCircle('cb-a');
    const token = await mintInvite('cb-a', circle.id);

    await bootstrap('cb-b');
    await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-b',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });

    // B pushes a doc.
    const bPush = await push('cb-b', circle.id, {
      docs: [
        {
          id: 'shared-1',
          collection: 'appointment',
          payload: '{"when":"tue"}',
          client_updated_at: 999,
        },
      ],
    });
    expect(bPush.status).toBe(200);
    expect(bPush.body.applied[0].accepted).toBe(true);

    // A pulls full and sees B's doc.
    const aPull = await pull('cb-a', circle.id, 0);
    const shared = aPull.body.docs.find((d) => d.id === 'shared-1');
    expect(shared?.payload).toBe('{"when":"tue"}');
  });

  it('a member who joins adopts the existing circle patient via pull', async () => {
    await bootstrap('cb-jp-owner');
    const circle = await createCircle('cb-jp-owner');
    await push('cb-jp-owner', circle.id, {
      patient: {
        payload: JSON.stringify({ name: 'Mary' }),
        client_updated_at: Date.now() + 60_000,
      },
      docs: [],
    });
    const token = await mintInvite('cb-jp-owner', circle.id);

    await bootstrap('cb-jp-joiner');
    await authedFetch('/api/v1/circles/join', {
      method: 'POST',
      sub: 'cb-jp-joiner',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });

    const joinerPull = await pull('cb-jp-joiner', circle.id, 0);
    expect(joinerPull.body.patient?.payload).toBe(
      JSON.stringify({ name: 'Mary' }),
    );
  });
});

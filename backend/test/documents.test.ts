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
  return (await res.json()) as { id: string };
}

beforeEach(async () => {
  await clearTables();
});

describe('documents blob storage', () => {
  it('uploads and downloads a blob round-trip', async () => {
    await bootstrap('cb-doc-owner');
    const circle = await createCircle('cb-doc-owner');

    const bytes = new Uint8Array([1, 2, 3, 4, 5, 250, 200, 0]);
    const put = await authedFetch(
      `/api/v1/documents/blob/${circle.id}/idcard-front.jpg`,
      {
        method: 'PUT',
        sub: 'cb-doc-owner',
        headers: { 'Content-Type': 'image/jpeg' },
        body: bytes,
      },
    );
    expect(put.status).toBe(200);
    const { key } = (await put.json()) as { key: string };
    expect(key).toBe(`documents/${circle.id}/idcard-front.jpg`);

    const get = await authedFetch(
      `/api/v1/documents/blob/${circle.id}/idcard-front.jpg`,
      { sub: 'cb-doc-owner' },
    );
    expect(get.status).toBe(200);
    expect(get.headers.get('Content-Type')).toBe('image/jpeg');
    const got = new Uint8Array(await get.arrayBuffer());
    expect(Array.from(got)).toEqual(Array.from(bytes));
  });

  it('rejects a non-member upload with 403', async () => {
    await bootstrap('cb-doc-owner2');
    const circle = await createCircle('cb-doc-owner2');
    await bootstrap('cb-doc-outsider');

    const res = await authedFetch(
      `/api/v1/documents/blob/${circle.id}/secret.jpg`,
      {
        method: 'PUT',
        sub: 'cb-doc-outsider',
        headers: { 'Content-Type': 'image/jpeg' },
        body: new Uint8Array([9, 9, 9]),
      },
    );
    expect(res.status).toBe(403);
  });

  it('rejects a non-member download with 403', async () => {
    await bootstrap('cb-doc-owner3');
    const circle = await createCircle('cb-doc-owner3');
    await authedFetch(`/api/v1/documents/blob/${circle.id}/poa.jpg`, {
      method: 'PUT',
      sub: 'cb-doc-owner3',
      headers: { 'Content-Type': 'image/jpeg' },
      body: new Uint8Array([1, 2, 3]),
    });
    await bootstrap('cb-doc-outsider3');

    const res = await authedFetch(
      `/api/v1/documents/blob/${circle.id}/poa.jpg`,
      { sub: 'cb-doc-outsider3' },
    );
    expect(res.status).toBe(403);
  });

  it('returns 404 for a missing key', async () => {
    await bootstrap('cb-doc-miss');
    const circle = await createCircle('cb-doc-miss');

    const res = await authedFetch(
      `/api/v1/documents/blob/${circle.id}/does-not-exist.jpg`,
      { sub: 'cb-doc-miss' },
    );
    expect(res.status).toBe(404);
  });

  it('returns 413 when the payload exceeds the size cap', async () => {
    await bootstrap('cb-doc-big');
    const circle = await createCircle('cb-doc-big');

    const big = new Uint8Array(8 * 1024 * 1024 + 1);
    const res = await authedFetch(
      `/api/v1/documents/blob/${circle.id}/huge.jpg`,
      {
        method: 'PUT',
        sub: 'cb-doc-big',
        headers: { 'Content-Type': 'image/jpeg' },
        body: big,
      },
    );
    expect(res.status).toBe(413);
  });

  it('returns 404 for an unknown circle', async () => {
    await bootstrap('cb-doc-nocircle');
    const res = await authedFetch(
      '/api/v1/documents/blob/does-not-exist/x.jpg',
      { sub: 'cb-doc-nocircle' },
    );
    expect(res.status).toBe(404);
  });

  it('requires authentication', async () => {
    const res = await SELF.fetch(
      `${ORIGIN}/api/v1/documents/blob/some-circle/x.jpg`,
      { method: 'PUT', body: new Uint8Array([1]) },
    );
    expect(res.status).toBe(401);
  });
});

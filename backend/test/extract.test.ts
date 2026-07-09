import { SELF, env, fetchMock } from 'cloudflare:test';
import { sign } from 'hono/jwt';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';

const SECRET = env.FORUM_JWT_SECRET;
const ORIGIN = 'https://forum.holdclose.local';
const AI_HOST = 'https://ai.holdclose.test';

// A 1x1 PNG, base64 — just needs to be a valid non-empty image string.
const TINY_PNG =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

const nowSec = () => Math.floor(Date.now() / 1000);
async function mintToken(sub: string) {
  const iat = nowSec();
  return sign({ sub, iat, exp: iat + 3600 }, SECRET, 'HS256');
}

async function extract(sub: string, body: unknown) {
  const token = await mintToken(sub);
  return SELF.fetch(`${ORIGIN}/api/v1/extract`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
}

function mockExtractAI(output: string) {
  fetchMock
    .get(AI_HOST)
    .intercept({ path: '/v1/chat/completions', method: 'POST' })
    .reply(200, { choices: [{ message: { content: output } }] });
}

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});
beforeEach(async () => {
  await env.FORUM_DB.prepare('DELETE FROM llm_usage').run();
});
afterEach(() => {
  fetchMock.assertNoPendingInterceptors();
});

describe('POST /api/v1/extract', () => {
  it('rejects unauthenticated callers (no inference call)', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/extract`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ user: 'read this', image_base64: TINY_PNG }),
    });
    expect(res.status).toBe(401);
  });

  it('returns the model text and logs usage tagged extract', async () => {
    mockExtractAI('{"name":"Lisinopril","dosage":"10 mg"}');
    const res = await extract('scanner-user', {
      system: 'extract the label',
      user: 'return JSON',
      image_base64: TINY_PNG,
    });
    expect(res.status).toBe(200);
    const json = (await res.json()) as { text: string };
    expect(json.text).toContain('Lisinopril');

    let row: { feature: string } | null = null;
    for (let i = 0; i < 40 && !row; i++) {
      row = await env.FORUM_DB.prepare(
        'SELECT feature FROM llm_usage WHERE user_id = ?',
      )
        .bind('scanner-user')
        .first<{ feature: string }>();
      if (!row) await new Promise((r) => setTimeout(r, 25));
    }
    expect(row?.feature).toBe('extract');
  });

  it('rejects a request with no image (400, no inference call)', async () => {
    const res = await extract('scanner-user', { user: 'no image here' });
    expect(res.status).toBe(400);
  });
});

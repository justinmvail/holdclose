import { SELF, env, fetchMock } from 'cloudflare:test';
import { sign } from 'hono/jwt';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';

const SECRET = env.FORUM_JWT_SECRET;
const ORIGIN = 'https://forum.holdclose.local';
// Matches CF_AI_BASE_URL in vitest.config.ts (a mockable stand-in for the
// Workers AI OpenAI-compatible endpoint).
const AI_HOST = 'https://ai.holdclose.test';

const nowSec = () => Math.floor(Date.now() / 1000);

async function mintToken(sub: string) {
  const iat = nowSec();
  return sign({ sub, iat, exp: iat + 3600 }, SECRET, 'HS256');
}

async function chat(sub: string, body: unknown) {
  const token = await mintToken(sub);
  return SELF.fetch(`${ORIGIN}/api/v1/chat`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
}

async function clearUsage() {
  await env.FORUM_DB.prepare('DELETE FROM llm_usage').run();
}

async function seedUsage(opts: {
  userId: string;
  promptTokens?: number;
  completionTokens?: number;
  costMicros?: number;
}) {
  await env.FORUM_DB.prepare(
    `INSERT INTO llm_usage
       (id, user_id, created_at, model, prompt_tokens, completion_tokens, cost_micros)
     VALUES (?, ?, ?, 'test-model', ?, ?, ?)`,
  )
    .bind(
      crypto.randomUUID(),
      opts.userId,
      Date.now(),
      opts.promptTokens ?? 0,
      opts.completionTokens ?? 0,
      opts.costMicros ?? 0,
    )
    .run();
}

/** OpenAI-style streaming SSE body (what the Workers AI OpenAI-compatible
 * endpoint returns): two content deltas + a final usage chunk + the
 * terminator. chat.ts re-emits these as vendor-neutral `data:{"text":…}`. */
function sseBody(prompt: number, completion: number) {
  return [
    'data: {"choices":[{"delta":{"content":"Hello"}}]}',
    '',
    'data: {"choices":[{"delta":{"content":" there"}}]}',
    '',
    `data: {"choices":[],"usage":{"prompt_tokens":${prompt},"completion_tokens":${completion}}}`,
    '',
    'data: [DONE]',
    '',
  ].join('\n');
}

function mockAI(prompt: number, completion: number) {
  fetchMock
    .get(AI_HOST)
    .intercept({ path: '/v1/chat/completions', method: 'POST' })
    .reply(200, sseBody(prompt, completion), {
      headers: { 'content-type': 'text/event-stream' },
    });
}

async function usageRow(userId: string, tries = 40) {
  for (let i = 0; i < tries; i++) {
    const row = await env.FORUM_DB.prepare(
      'SELECT * FROM llm_usage WHERE user_id = ?',
    )
      .bind(userId)
      .first<{
        prompt_tokens: number;
        completion_tokens: number;
        cost_micros: number;
        feature: string;
      }>();
    if (row) return row;
    await new Promise((r) => setTimeout(r, 25));
  }
  return null;
}

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

beforeEach(async () => {
  await clearUsage();
});

afterEach(() => {
  fetchMock.assertNoPendingInterceptors();
});

describe('POST /api/v1/chat', () => {
  it('rejects unauthenticated callers (no inference call)', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ system: 's', user: 'u' }),
    });
    expect(res.status).toBe(401);
  });

  it('streams a vendor-neutral reply and logs real token usage', async () => {
    mockAI(1200, 8);
    const res = await chat('user-happy', { system: 'be kind', user: 'hi' });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/event-stream');

    const text = await res.text();
    expect(text).toContain('data: {"text":"Hello"}');
    expect(text).toContain('data: {"text":" there"}');
    expect(text).toContain('data: [DONE]');
    // The upstream JSON shape must NOT leak through.
    expect(text).not.toContain('choices');

    const row = await usageRow('user-happy');
    expect(row).not.toBeNull();
    expect(row?.prompt_tokens).toBe(1200);
    expect(row?.completion_tokens).toBe(8);
    // 1200*0.35 + 8*0.75 = 426 micro-dollars
    expect(row?.cost_micros).toBe(426);
    expect(row?.feature).toBe('chat');
  });

  it('records the feature tag for per-surface accounting', async () => {
    mockAI(500, 4);
    const res = await chat('user-recap', {
      system: 'summarize',
      user: 'events',
      feature: 'recap',
    });
    expect(res.status).toBe(200);
    await res.text();

    const row = await usageRow('user-recap');
    expect(row?.feature).toBe('recap');
  });

  it('rejects an oversized prompt with 413 (no inference call)', async () => {
    const res = await chat('user-big', {
      system: 'x'.repeat(40_000),
      user: 'y'.repeat(20_000),
    });
    expect(res.status).toBe(413);
  });

  it('blocks a user who is over the daily token quota with 429', async () => {
    await seedUsage({ userId: 'user-capped', promptTokens: 300_000 });
    const res = await chat('user-capped', { system: 's', user: 'u' });
    expect(res.status).toBe(429);
  });

  it('trips the global daily spend circuit breaker with 503', async () => {
    await seedUsage({ userId: 'whale', costMicros: 5_000_000 });
    const res = await chat('user-fresh', { system: 's', user: 'u' });
    expect(res.status).toBe(503);
  });
});

/// Live-backend integration suite — exercises the DEPLOYED Cloudflare
/// Worker end-to-end over real HTTPS: real D1, real R2, real Workers-AI
/// inference, real edge routing. This is the post-migration acceptance
/// suite; the hermetic `npm test` suite (vitest-pool-workers + miniflare)
/// can never catch a binding/secret/route problem that only exists on the
/// deployed environment.
///
/// AUTH MODEL: the Worker mints HS256 session JWTs with FORUM_JWT_SECRET
/// (see src/middleware/auth.ts). We hold that secret for the dev
/// environment (backend/.dev.vars), so the suite forges its own session
/// tokens — no Google OAuth round-trip needed. Two disposable identities
/// (an owner + a joiner) are created through the PUBLIC API only
/// (/profiles/bootstrap), never by touching D1 directly, and both are
/// hard-deleted through DELETE /profiles/me in afterAll — so repeated runs
/// don't accrete rows in the dev database.
///
/// SAFETY RAILS:
///  * Refuses to run against anything that looks like production
///    (holdclose.care) unless LIVE_ALLOW_PROD=1 is set explicitly.
///  * All created data is namespaced `live-test-…` and deleted afterwards
///    (account deletion cascades posts/comments/votes/circles/sync docs).
///  * The suite makes exactly ONE real chat inference and ONE extract
///    attempt — enough to prove the wiring, cheap enough to run freely.
///
/// Config (env):
///  * LIVE_BASE_URL     — Worker origin (default: the CF dev deploy).
///  * FORUM_JWT_SECRET  — session secret; falls back to backend/.dev.vars.
///  * LIVE_ALLOW_PROD=1 — required to point at holdclose.care.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { sign } from 'hono/jwt';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';

const BASE_URL = (
  process.env.LIVE_BASE_URL ??
  'https://holdclose-forum-dev.jcsvonellc.workers.dev'
).replace(/\/$/, '');

if (/holdclose\.care/i.test(BASE_URL) && process.env.LIVE_ALLOW_PROD !== '1') {
  throw new Error(
    'live suite pointed at PRODUCTION — set LIVE_ALLOW_PROD=1 if you truly mean it',
  );
}

/** The dev session secret: env first, then backend/.dev.vars. */
function jwtSecret(): string {
  const fromEnv = process.env.FORUM_JWT_SECRET;
  if (fromEnv && fromEnv.length > 0) return fromEnv;
  const devVarsPath = join(
    dirname(fileURLToPath(import.meta.url)),
    '..',
    '.dev.vars',
  );
  const line = readFileSync(devVarsPath, 'utf8')
    .split('\n')
    .find((l) => l.startsWith('FORUM_JWT_SECRET='));
  if (!line) {
    throw new Error(
      'FORUM_JWT_SECRET not in env and not found in backend/.dev.vars',
    );
  }
  return line.slice('FORUM_JWT_SECRET='.length).trim().replace(/^"|"$/g, '');
}

const SECRET = jwtSecret();

/** Forge a session JWT exactly as POST /auth/google would mint it. */
async function forgeSession(sub: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return sign({ sub, iat: now, exp: now + 60 * 60 }, SECRET, 'HS256');
}

// Cloudflare's edge 403s some non-browser User-Agents (error 1010); the
// app's dio client is unaffected, so present a browser-ish UA here too.
const USER_AGENT = 'Mozilla/5.0 (HoldcloseLiveSuite)';

type ApiInit = {
  method?: string;
  token?: string;
  json?: unknown;
  body?: BodyInit;
  contentType?: string;
};

async function api(path: string, init: ApiInit = {}): Promise<Response> {
  const headers: Record<string, string> = { 'User-Agent': USER_AGENT };
  if (init.token) headers.Authorization = `Bearer ${init.token}`;
  let body: BodyInit | undefined = init.body;
  if (init.json !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(init.json);
  }
  if (init.contentType) headers['Content-Type'] = init.contentType;
  return fetch(`${BASE_URL}${path}`, {
    method: init.method ?? (body === undefined ? 'GET' : 'POST'),
    headers,
    body,
  });
}

// 1×1 transparent PNG (67 bytes) — a legal image for extract + R2 uploads.
const TINY_PNG_BASE64 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf' +
  'DwAChwGA60e6kgAAAABJRU5ErkJggg==';

const RUN_ID = `live-test-${Date.now()}`;
const USER_A = `${RUN_ID}-owner`;
const USER_B = `${RUN_ID}-joiner`;

let tokenA = '';
let tokenB = '';
// Populated as the flows run; later tests consume earlier results.
let profileAId = '';
let circleId = '';
let inviteToken = '';
let postId = '';
let commentId = '';

beforeAll(async () => {
  tokenA = await forgeSession(USER_A);
  tokenB = await forgeSession(USER_B);
});

afterAll(async () => {
  // Best-effort teardown even when tests failed mid-flow: account deletion
  // cascades circles/sync docs/posts/comments/votes/reports + R2 blobs.
  for (const token of [tokenB, tokenA]) {
    if (!token) continue;
    await api('/api/v1/profiles/me', { method: 'DELETE', token }).catch(
      () => undefined,
    );
  }
});

const BACKEND_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');

/// Run one SQL statement against the DEPLOYED D1.
///
/// For rows the public API can't reach: usage-ledger rows that trip the spend
/// caps, and feedback rows (which survive account deletion — they're keyed by
/// the JWT sub, not a profile FK).
function d1(sql: string): void {
  execFileSync(
    'npx',
    [
      'wrangler',
      'd1',
      'execute',
      'holdclose-forum-dev',
      '--env',
      'dev',
      '--remote',
      '--command',
      sql,
    ],
    { cwd: BACKEND_DIR, stdio: 'pipe' },
  );
}

describe('public surface', () => {
  it('GET /health is ok', async () => {
    const res = await api('/health');
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: 'ok' });
  });

  it('GET /terms and /privacy serve legal HTML at the worker root', async () => {
    for (const path of ['/terms', '/privacy']) {
      const res = await api(path);
      expect(res.status, path).toBe(200);
      expect(res.headers.get('content-type') ?? '', path).toContain('text/html');
    }
  });

  it('GET /join/:token serves the invite landing page with the deep link', async () => {
    const res = await api('/join/some-live-probe-token');
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('holdclose://join/');
  });

  it('protected routes 401 without a token, with a garbage token, and with a wrong-secret token', async () => {
    const noToken = await api('/api/v1/profiles/me');
    expect(noToken.status).toBe(401);

    const garbage = await api('/api/v1/profiles/me', { token: 'not-a-jwt' });
    expect(garbage.status).toBe(401);

    const now = Math.floor(Date.now() / 1000);
    const wrongSecret = await sign(
      { sub: 'intruder', iat: now, exp: now + 3600 },
      'the-wrong-secret',
      'HS256',
    );
    const forged = await api('/api/v1/profiles/me', { token: wrongSecret });
    expect(forged.status).toBe(401);
  });

  it('POST /auth/google rejects a missing / invalid Google id_token', async () => {
    const missing = await api('/api/v1/auth/google', { json: {} });
    expect(missing.status).toBe(400);

    const invalid = await api('/api/v1/auth/google', {
      json: { id_token: 'garbage.garbage.garbage' },
    });
    expect(invalid.status).toBe(401);
  });
});

describe('profiles', () => {
  it('bootstrap creates (or returns) the owner profile', async () => {
    const res = await api('/api/v1/profiles/bootstrap', {
      method: 'POST',
      token: tokenA,
    });
    expect([200, 201]).toContain(res.status);
    const body = (await res.json()) as { id: string; display_name: string };
    expect(body.id).toBeTruthy();
    expect(body.display_name).toBeTruthy();
    profileAId = body.id;
  });

  it('GET /me returns the profile', async () => {
    const res = await api('/api/v1/profiles/me', { token: tokenA });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string };
    expect(body.id).toBe(profileAId);
  });

  it('PATCH /me updates display_name', async () => {
    const res = await api('/api/v1/profiles/me', {
      method: 'PATCH',
      token: tokenA,
      json: { display_name: `live_owner_${Date.now() % 100000}` },
    });
    expect(res.status).toBe(200);
  });

  it('PATCH /me enforces the profanity guardrail live', async () => {
    const res = await api('/api/v1/profiles/me', {
      method: 'PATCH',
      token: tokenA,
      json: { display_name: 'MegaShit99' },
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: 'profanity_blocked' });
  });

  it('username availability + public lookup work', async () => {
    const avail = await api(
      `/api/v1/profiles/username-available?u=nobody_${Date.now() % 100000}`,
      { token: tokenA },
    );
    expect(avail.status).toBe(200);
    expect(
      ((await avail.json()) as { available: boolean }).available,
    ).toBe(true);

    const byId = await api(`/api/v1/profiles/${profileAId}`, {
      token: tokenA,
    });
    expect(byId.status).toBe(200);
  });
});

describe('care circles + invites', () => {
  it('owner creates a circle with an initial loved-one payload', async () => {
    const res = await api('/api/v1/circles', {
      method: 'POST',
      token: tokenA,
      json: {
        name: `${RUN_ID} circle`,
        patient: {
          payload: JSON.stringify({ name: 'Live Test Loved One' }),
          client_updated_at: Date.now(),
        },
      },
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { id: string };
    expect(body.id).toBeTruthy();
    circleId = body.id;
  });

  it('owner sees the circle in GET /circles', async () => {
    const res = await api('/api/v1/circles', { token: tokenA });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { circles?: unknown[] } | unknown[];
    const list = Array.isArray(body) ? body : (body.circles ?? []);
    expect(JSON.stringify(list)).toContain(circleId);
  });

  it('owner mints a single-use invite', async () => {
    const res = await api(`/api/v1/circles/${circleId}/invites`, {
      method: 'POST',
      token: tokenA,
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { token: string; expires_at: string };
    expect(body.token).toBeTruthy();
    inviteToken = body.token;
  });

  it('joiner bootstraps and joins with the invite; the token is single-use', async () => {
    const boot = await api('/api/v1/profiles/bootstrap', {
      method: 'POST',
      token: tokenB,
    });
    expect([200, 201]).toContain(boot.status);

    const join = await api('/api/v1/circles/join', {
      method: 'POST',
      token: tokenB,
      json: { token: inviteToken },
    });
    expect([200, 201]).toContain(join.status);

    // Single-use is about a SECOND PERSON replaying a consumed link — that
    // must be refused (410 invite_used). The joiner re-tapping their own
    // link is deliberately idempotent (they short-circuit as an existing
    // member without re-consuming), so replaying as tokenB proves nothing.
    const thirdParty = await forgeSession(`${RUN_ID}-replayer`);
    await api('/api/v1/profiles/bootstrap', {
      method: 'POST',
      token: thirdParty,
    });
    const replay = await api('/api/v1/circles/join', {
      method: 'POST',
      token: thirdParty,
      json: { token: inviteToken },
    });
    expect(replay.status).toBe(410);
    expect(await replay.json()).toEqual({ error: 'invite_used' });

    // Clean up the throwaway third identity.
    await api('/api/v1/profiles/me', {
      method: 'DELETE',
      token: thirdParty,
    });
  });

  it('a non-member cannot mint invites for the circle', async () => {
    const outsider = await forgeSession(`${RUN_ID}-outsider`);
    // No bootstrap → no profile → must be rejected, never 2xx.
    const res = await api(`/api/v1/circles/${circleId}/invites`, {
      method: 'POST',
      token: outsider,
    });
    expect(res.status).toBeGreaterThanOrEqual(400);
  });
});

describe('sync (server-authoritative care data)', () => {
  const medDocId = `${RUN_ID}-med-1`;

  it('owner pushes a patient + docs batch', async () => {
    const res = await api(`/api/v1/sync/${circleId}`, {
      method: 'POST',
      token: tokenA,
      json: {
        patient: {
          payload: JSON.stringify({ name: 'Live Test Loved One', v: 2 }),
          client_updated_at: Date.now(),
        },
        docs: [
          {
            id: medDocId,
            collection: 'medication',
            payload: JSON.stringify({ name: 'Lisinopril', dose: '10 mg' }),
            client_updated_at: Date.now(),
          },
          {
            id: `${RUN_ID}-journal-1`,
            collection: 'journal_entries',
            payload: JSON.stringify({ situation: 'live smoke test' }),
            client_updated_at: Date.now(),
          },
        ],
      },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { cursor: number };
    expect(body.cursor).toBeGreaterThan(0);
  });

  it('joiner pulls the pushed data', async () => {
    const res = await api(`/api/v1/sync/${circleId}?since=0`, {
      token: tokenB,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      patient: { payload: string } | null;
      docs: Array<{ id: string; payload: string }>;
    };
    expect(body.patient?.payload).toContain('Live Test Loved One');
    const ids = body.docs.map((d) => d.id);
    expect(ids).toContain(medDocId);
    expect(ids).toContain(`${RUN_ID}-journal-1`);
  });

  it('last-write-wins: a STALE update does not clobber newer data', async () => {
    const res = await api(`/api/v1/sync/${circleId}`, {
      method: 'POST',
      token: tokenB,
      json: {
        docs: [
          {
            id: medDocId,
            collection: 'medication',
            payload: JSON.stringify({ name: 'STALE OVERWRITE' }),
            client_updated_at: Date.now() - 7 * 24 * 60 * 60 * 1000,
          },
        ],
      },
    });
    expect(res.status).toBe(200);

    const pull = await api(`/api/v1/sync/${circleId}?since=0`, {
      token: tokenA,
    });
    const body = (await pull.json()) as {
      docs: Array<{ id: string; payload: string }>;
    };
    const med = body.docs.find((d) => d.id === medDocId);
    expect(med?.payload).toContain('Lisinopril');
    expect(med?.payload).not.toContain('STALE OVERWRITE');
  });

  it('a non-member cannot read the circle sync feed', async () => {
    const outsider = await forgeSession(`${RUN_ID}-outsider-2`);
    const res = await api(`/api/v1/sync/${circleId}?since=0`, {
      token: outsider,
    });
    expect(res.status).toBeGreaterThanOrEqual(400);
  });
});

describe('document blobs (R2)', () => {
  const key = 'live-test-scan.png';
  const bytes = Uint8Array.from(atob(TINY_PNG_BASE64), (c) => c.charCodeAt(0));

  it('member uploads a scan blob', async () => {
    const res = await api(`/api/v1/documents/blob/${circleId}/${key}`, {
      method: 'PUT',
      token: tokenA,
      body: bytes,
      contentType: 'image/png',
    });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { key: string }).key).toContain(key);
  });

  it('member reads the blob back byte-identical', async () => {
    const res = await api(`/api/v1/documents/blob/${circleId}/${key}`, {
      token: tokenB,
    });
    expect(res.status).toBe(200);
    const got = new Uint8Array(await res.arrayBuffer());
    expect(got).toEqual(bytes);
  });

  it('active content types are rejected (415)', async () => {
    const res = await api(`/api/v1/documents/blob/${circleId}/evil.html`, {
      method: 'PUT',
      token: tokenA,
      body: '<script>alert(1)</script>',
      contentType: 'text/html',
    });
    expect(res.status).toBe(415);
  });
});

/// Profile avatars against the REAL edge: upload → R2 → public serve.
///
/// Worth a live test specifically because this feature's failure mode was
/// invisible to any hermetic suite: FORUM_MEDIA was bound but unused, no
/// upload route existed, and `R2_PUBLIC_URL` pointed at a placeholder domain
/// (`media.holdclose.local`) that resolved NOWHERE — so even a "correct"
/// avatar_url could never have loaded in a real app. The load-bearing
/// assertion here is that the URL the API mints actually FETCHES.
describe('profile avatars (R2 + public serving)', () => {
  const bytes = Uint8Array.from(atob(TINY_PNG_BASE64), (c) => c.charCodeAt(0));
  let avatarUrl = '';

  it('uploads the caregiver photo', async () => {
    const res = await api('/api/v1/profiles/avatar', {
      method: 'PUT',
      token: tokenA,
      body: bytes,
      contentType: 'image/png',
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { avatar_url: string };
    expect(body.avatar_url).toBeTruthy();
    avatarUrl = body.avatar_url;
  });

  it('the minted avatar_url actually RESOLVES over the public internet', async () => {
    // Not `api(...)`: fetch the absolute URL the API handed us, exactly as a
    // phone rendering the community feed would — no session, no base-path
    // assumptions. If R2_PUBLIC_URL is ever pointed at a domain that does not
    // serve, this is the test that catches it.
    const res = await fetch(avatarUrl, {
      headers: { 'User-Agent': USER_AGENT },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('image/png');
    expect(res.headers.get('x-content-type-options')).toBe('nosniff');
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(bytes);
  });

  it('an SVG "avatar" is refused — it would execute on our own origin', async () => {
    const res = await api('/api/v1/profiles/avatar', {
      method: 'PUT',
      token: tokenA,
      body: '<svg onload="alert(1)"/>',
      contentType: 'image/svg+xml',
    });
    expect(res.status).toBe(415);
  });

  it('the photo rides along with the caregiver’s posts', async () => {
    const created = await api('/api/v1/posts', {
      method: 'POST',
      token: tokenA,
      json: {
        title: `${RUN_ID}: a post with a face`,
        body: 'Live smoke-test post — auto-deleted.',
      },
    });
    expect(created.status).toBe(201);
    const post = (await created.json()) as {
      id: string;
      author_avatar_url: string | null;
    };
    expect(post.author_avatar_url).toBe(avatarUrl);
    await api(`/api/v1/posts/${post.id}`, { method: 'DELETE', token: tokenA });
  });

  // NOTE: the purge-on-account-deletion path is asserted in the account
  // deletion block below (`deleted.avatars`), which runs last and tears this
  // photo down — a caregiver's face must not outlive their account.
});

describe('community forum', () => {
  it('owner creates a post', async () => {
    const res = await api('/api/v1/posts', {
      method: 'POST',
      token: tokenA,
      json: {
        title: `${RUN_ID}: how do you handle pharmacy runs?`,
        body: 'Live smoke-test post — safe to ignore, auto-deleted.',
      },
    });
    expect(res.status).toBe(201);
    postId = ((await res.json()) as { id: string }).id;
    expect(postId).toBeTruthy();
  });

  it('the feed is read-anonymous and contains the post', async () => {
    const res = await api(`/api/v1/posts/${postId}`);
    expect(res.status).toBe(200);
  });

  it('joiner comments on the post', async () => {
    const res = await api(`/api/v1/posts/${postId}/comments`, {
      method: 'POST',
      token: tokenB,
      json: { body: 'live smoke-test comment' },
    });
    expect(res.status).toBe(201);
    commentId = ((await res.json()) as { id: string }).id;
  });

  it('joiner votes the post up', async () => {
    const res = await api('/api/v1/votes', {
      method: 'POST',
      token: tokenB,
      json: { target_kind: 'post', target_id: postId, value: 1 },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { vote_count: number; value: number };
    expect(body.value).toBe(1);
  });

  it('joiner reports the post (moderation intake works)', async () => {
    const res = await api('/api/v1/reports', {
      method: 'POST',
      token: tokenB,
      json: {
        target_kind: 'post',
        target_id: postId,
        reason: 'live smoke-test report — ignore',
      },
    });
    expect([200, 201]).toContain(res.status);
  });

  it('authors can edit and delete their own content', async () => {
    const edit = await api(`/api/v1/posts/${postId}`, {
      method: 'PATCH',
      token: tokenA,
      json: { body: 'edited live smoke-test post body' },
    });
    expect(edit.status).toBe(200);

    const delComment = await api(`/api/v1/comments/${commentId}`, {
      method: 'DELETE',
      token: tokenB,
    });
    expect([200, 204]).toContain(delComment.status);

    const delPost = await api(`/api/v1/posts/${postId}`, {
      method: 'DELETE',
      token: tokenA,
    });
    expect([200, 204]).toContain(delPost.status);
  });
});

describe('AI coach (Workers-AI binding)', () => {
  // FINDING (2026-07-13): the reply text streams fine, but the stream never
  // terminates — `[DONE]` is never emitted and the Workers runtime kills the
  // request ("your Worker's code had hung"; outcome=exception in
  // `wrangler tail`). chat.ts's pump SKIPS the upstream `data: [DONE]`
  // sentinel and waits for the reader's `done`, which the native AI binding
  // never signals. Consequence: `logUsage()` (in that same done branch)
  // NEVER RUNS — llm_usage is empty on the deploy, so the per-user daily
  // token cap AND the global daily spend cap are both unenforced.
  it('streams a vendor-neutral SSE reply from real inference', async () => {
    const res = await api('/api/v1/chat', {
      method: 'POST',
      token: tokenA,
      json: {
        system:
          'You are a supportive caregiving coach. Reply in one short sentence.',
        user: 'Say hello to a caregiver testing the app.',
      },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type') ?? '').toContain(
      'text/event-stream',
    );

    const raw = await res.text();
    // Vendor-neutral wire contract: `data: {"text":"…"}` deltas + [DONE].
    expect(raw).toContain('data:');
    expect(raw).toContain('[DONE]');
    const text = raw
      .split('\n')
      .filter((l) => l.startsWith('data:') && l.includes('"text"'))
      .map((l) => (JSON.parse(l.slice(5)) as { text: string }).text)
      .join('');
    expect(text.trim().length).toBeGreaterThan(0);
    // The vendor/model must never reach the client.
    expect(raw.toLowerCase()).not.toContain('llama');
    expect(raw.toLowerCase()).not.toContain('cloudflare');
  });
});

describe('AI extract (scan-to-import vision path)', () => {
  // FINDING (2026-07-13), two layers deep:
  //  (a) FIXED — extract.ts required the REST CF_AI_API_TOKEN secret, which is
  //      not set on env.dev, so it 500'd server_misconfigured while chat (long
  //      since migrated to the native env.AI binding) worked. It now prefers
  //      the binding, exactly like chat.
  //  (b) STILL BLOCKED, and NOT a code bug: the vision model is LICENCE-GATED.
  //      Workers AI rejects it with `AiError 5016` — "Prior to using this
  //      model, you must submit the prompt 'agree'" — until the ACCOUNT accepts
  //      Meta's Llama 3.2 Community Licence. That is a one-time legal act for
  //      the operating company, so it is deliberately not automated. See
  //      backend/README.md → "Vision model licence". Until it's accepted,
  //      scan-to-import (Rx / appointment / insurance-card capture) is DOWN on
  //      this backend and this test fails with 502 extract_unavailable.
  it('extracts from an image', async () => {
    const res = await api('/api/v1/extract', {
      method: 'POST',
      token: tokenA,
      json: {
        system: 'Reply with the exact JSON: {"ok":true}',
        user: 'Describe this image as the JSON above.',
        image_base64: TINY_PNG_BASE64,
      },
    });
    // Memory/docs say extract still rides the REST CF_AI_API_TOKEN path and
    // hasn't been migrated to the env-scoped AI binding — if this fails
    // with 500 server_misconfigured, that's the finding to address.
    expect(res.status).toBe(200);
    const body = (await res.json()) as { text?: string };
    expect((body.text ?? '').length).toBeGreaterThan(0);
  });
});

/// The cost/abuse circuit breakers, proved against the REAL deploy.
///
/// These matter more than the average test: until 2026-07-13 they were
/// silently DEAD in production. `llm_usage` never got a row (the chat stream
/// never terminated, so the usage insert in that branch never ran), and BOTH
/// limits are computed from that table — so the coach had no per-user quota
/// and no daily spend ceiling on a publicly reachable endpoint. A green
/// "chat works" test said nothing about it. These say it out loud.
///
/// We seed `llm_usage` directly in the live D1 via `wrangler d1 execute
/// --remote` rather than burning hundreds of real inferences to reach the
/// ceiling. Every seeded row is namespaced `live-test-…` and deleted in
/// afterEach, including on failure.
describe('LLM cost controls (the circuit breakers)', () => {
  /** Seed a usage row for [userId], dated NOW so it lands in today's window. */
  function seedUsage(
    userId: string,
    opts: { tokens?: number; costMicros?: number },
  ): void {
    d1(
      `INSERT INTO llm_usage
         (id, user_id, created_at, model, feature, prompt_tokens, completion_tokens, cost_micros)
       VALUES
         ('${RUN_ID}-${crypto.randomUUID()}', '${userId}', ${Date.now()},
          'live-test-model', 'chat', ${opts.tokens ?? 0}, 0, ${opts.costMicros ?? 0})`,
    );
  }

  afterEach(() => {
    // ALWAYS clean up: a leftover global-cap row would keep the coach
    // "resting" for every user on this backend until UTC midnight.
    d1(`DELETE FROM llm_usage WHERE user_id LIKE 'live-test-%'`);
  });

  it('per-user daily token quota trips → 429 daily_limit', async () => {
    // CHAT_USER_DAILY_TOKENS = 300_000 on this env; the check is `>=`.
    const quotaUser = `live-test-quota-${Date.now()}`;
    seedUsage(quotaUser, { tokens: 300_000 });

    const token = await forgeSession(quotaUser);
    const res = await api('/api/v1/chat', {
      method: 'POST',
      token,
      json: { system: 'coach', user: 'hello' },
    });

    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: 'daily_limit' });
  });

  it('a user UNDER the quota is still served (the limit is not a blanket block)', async () => {
    const okUser = `live-test-underquota-${Date.now()}`;
    seedUsage(okUser, { tokens: 10 });

    const token = await forgeSession(okUser);
    const res = await api('/api/v1/chat', {
      method: 'POST',
      token,
      json: { system: 'Reply with exactly: OK', user: 'hi' },
    });

    expect(res.status).toBe(200);
    // ...and the reply STREAMS TO COMPLETION. This is the regression that
    // hung the Worker and killed usage logging: no terminator, no metering.
    const raw = await res.text();
    expect(raw).toContain('[DONE]');
  });

  it('global daily spend cap trips → 503 capacity (the coach rests, it does not bill on)', async () => {
    // cap = max(CHAT_GLOBAL_FLOOR_MICROS $5.00, per-user budget × users).
    // One row past the floor is enough to prove the breaker fires.
    seedUsage(`live-test-spend-${Date.now()}`, { costMicros: 6_000_000 });

    const token = await forgeSession(`live-test-anyone-${Date.now()}`);
    const res = await api('/api/v1/chat', {
      method: 'POST',
      token,
      json: { system: 'coach', user: 'hello' },
    });

    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: 'capacity' });
  });

  it('an oversized prompt is refused before any inference → 413', async () => {
    const token = await forgeSession(`live-test-oversize-${Date.now()}`);
    const res = await api('/api/v1/chat', {
      method: 'POST',
      token,
      // CHAT_MAX_INPUT_CHARS = 48_000.
      json: { system: 'coach', user: 'x'.repeat(48_001) },
    });

    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: 'prompt_too_large' });
  });
});

/// The in-app Report button's destination, live.
///
/// This is the test that would have caught the outage: reports used to POST to
/// the operator's laptop shim, which went dark on 2026-07-10 when the backend
/// moved to Cloudflare and the Funnel was switched off — builds kept baking the
/// dead URL, so tester reports vanished for three days with no signal at all.
/// Now they land in the Worker's D1, and this asserts it against the real edge.
describe('tester feedback (the Report button)', () => {
  const reportId = `fb_${Date.now()}`;

  it('a signed-in tester can file a report with a screenshot', async () => {
    const res = await api('/api/v1/feedback', {
      method: 'POST',
      token: tokenA,
      json: {
        id: reportId,
        category: 'bug',
        message: `${RUN_ID}: live smoke-test report — safe to ignore.`,
        route: '/setup',
        tester_name: 'live-suite',
        platform: 'ios',
        os_version: 'Version 26.5.2',
        demo_mode: false,
        app_version: '0.1.0+30',
        build_stamp: `${Date.now()}`,
        created_at: new Date().toISOString(),
        has_screenshot: true,
        logs: 'live smoke-test log line',
        screenshot_base64: TINY_PNG_BASE64,
      },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ id: reportId, screenshot: true });
  });

  it('the screenshot is NOT exposed through the public media route', async () => {
    // A screenshot can show a loved one's care data. /media serves avatars and
    // nothing else — this is the assertion that keeps it that way.
    const res = await fetch(`${BASE_URL}/media/feedback/${reportId}.png`, {
      headers: { 'User-Agent': USER_AGENT },
    });
    expect(res.status).toBe(404);
  });

  it('a non-admin tester cannot read the triage queue (reports carry PHI)', async () => {
    const res = await api('/api/v1/feedback', { token: tokenA });
    expect(res.status).toBe(403);
  });

  afterAll(() => {
    // Feedback rows are keyed by the JWT sub, not a profile FK, so account
    // deletion does NOT cascade them — clean up explicitly.
    d1(`DELETE FROM feedback WHERE id = '${reportId}'`);
  });
});

describe('billing', () => {
  // NOTE: /verify returns 500 server_misconfigured on dev — APPLE_ISSUER_ID /
  // APPLE_KEY_ID / GOOGLE_PLAY_SA_EMAIL are empty placeholders at the top
  // level and absent from [env.dev.vars] (wrangler warns on every deploy),
  // and the store private keys aren't set as secrets. EXPECTED until the
  // App Store / Play products exist — not a migration regression. It stays
  // asserted so the day billing is configured, this suite proves it.
  it('GET /entitlement answers for a free-tier account', async () => {
    const res = await api('/api/v1/billing/entitlement', { token: tokenA });
    expect(res.status).toBe(200);
    expect(await res.json()).toBeTypeOf('object');
  });

  it('POST /verify rejects a garbage receipt without a 5xx', async () => {
    const res = await api('/api/v1/billing/verify', {
      method: 'POST',
      token: tokenA,
      json: {
        platform: 'ios',
        productId: 'live.test.product',
        receipt: 'garbage-receipt',
      },
    });
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(res.status).toBeLessThan(500);
  });
});

describe('account deletion (cleanup doubles as the test)', () => {
  // FINDING (2026-07-13): FAILS 500 for a member who JOINED VIA AN INVITE.
  // `circle_invites.used_by_profile_id` references profiles(id) with NO
  // `ON DELETE` action (its sibling FKs cascade), and deleteAccount() only
  // clears invites the caller CREATED — never the one they REDEEMED. The
  // final `DELETE FROM profiles` then trips the FK. => any care-circle
  // member who joined by link CANNOT delete their account. The hermetic
  // suite misses it: its tests add members directly, so used_by_profile_id
  // is never set.
  it('joiner deletes their account', async () => {
    const res = await api('/api/v1/profiles/me', {
      method: 'DELETE',
      token: tokenB,
    });
    expect(res.status).toBe(200);

    const gone = await api('/api/v1/profiles/me', { token: tokenB });
    expect(gone.status).toBe(404);
    tokenB = ''; // afterAll: nothing left to clean
  });

  it('owner deletes their account, cascading the circle + care data + their photo', async () => {
    const res = await api('/api/v1/profiles/me', {
      method: 'DELETE',
      token: tokenA,
    });
    expect(res.status).toBe(200);

    // The avatar uploaded earlier is served PUBLICLY, so it must not outlive
    // the account — the deletion reports it, and the URL must go dead.
    const { deleted } = (await res.clone().json()) as {
      deleted: Record<string, number>;
    };
    expect(deleted.avatars).toBe(1);

    // The circle must be unreachable afterwards.
    const sync = await api(`/api/v1/sync/${circleId}?since=0`, {
      token: tokenA,
    });
    expect(sync.status).toBeGreaterThanOrEqual(400);
    tokenA = '';
  });
});

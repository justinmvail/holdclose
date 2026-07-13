import { SELF, env } from 'cloudflare:test';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

/// Server-side tester reports (the Report button).
///
/// Context: these used to POST to `claude_shim.py` on the operator's laptop.
/// That pipe DIED SILENTLY when the backend moved to Cloudflare and the
/// laptop's LaunchAgents + Tailscale Funnel were disabled (2026-07-10) — builds
/// kept baking the dead funnel URL, so every report a tester filed went into a
/// black hole for three days, and nothing caught it because nothing tested it.
/// These tests are the thing that would have.
///
/// The properties that matter:
///  * a report is tied to a real account (JWT-gated write);
///  * a tester can FILE but never READ — reports carry other caregivers' PHI
///    (message, on-device logs, screenshot), so reads are admin-only;
///  * the screenshot is NOT reachable through the public /media route;
///  * delivery is IDEMPOTENT on the app-minted id, because the phone keeps a
///    durable outbox and re-sends anything it didn't get a 200 for.
const SECRET = env.FORUM_JWT_SECRET;
const ORIGIN = 'https://forum.holdclose.local';

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

/** The exact body shape the app's FeedbackSender posts. */
function report(overrides: Record<string, unknown> = {}) {
  return {
    id: `fb_${Date.now()}${Math.floor(Math.random() * 1000)}`,
    category: 'bug',
    message: 'The save button spins forever on the loved-one setup screen.',
    route: '/setup',
    tester_name: 'justin',
    platform: 'ios',
    os_version: 'Version 26.5.2',
    demo_mode: false,
    app_version: '0.1.0+30',
    build_stamp: '1783956142',
    created_at: new Date().toISOString(),
    has_screenshot: false,
    logs: 'FlutterError: something went wrong',
    ...overrides,
  };
}

async function post(sub: string, body: unknown) {
  return authedFetch('/api/v1/feedback', {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

/** A 1×1 PNG, base64 — what the app attaches as a screenshot. */
const PNG_B64 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

/** Promote a caregiver to admin (the operator's own account). */
async function makeAdmin(sub: string) {
  await authedFetch('/api/v1/profiles/bootstrap', { method: 'POST', sub });
  await env.FORUM_DB.prepare(
    'UPDATE profiles SET role = ? WHERE careblazers_user_id = ?',
  )
    .bind('admin', sub)
    .run();
}

async function clearAll() {
  await env.FORUM_DB.batch([
    env.FORUM_DB.prepare('DELETE FROM feedback'),
    env.FORUM_DB.prepare('DELETE FROM profiles'),
  ]);
  let cursor: string | undefined;
  do {
    const listed = await env.FORUM_MEDIA.list({ cursor });
    const keys = listed.objects.map((o) => o.key);
    if (keys.length > 0) await env.FORUM_MEDIA.delete(keys);
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
}

beforeEach(clearAll);

describe('POST /api/v1/feedback', () => {
  it('requires authentication — a report is always tied to an account', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/feedback`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(report()),
    });
    expect(res.status).toBe(401);
  });

  it('accepts the app’s report payload verbatim (no profile needed to file)', async () => {
    // Deliberately NOT bootstrapping a profile first: a tester hitting a bug
    // during onboarding — exactly when they most need to report — may not have
    // one yet. Filing must not depend on it.
    const body = report();
    const res = await post('cb-fb-tester', body);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ id: body.id, screenshot: false });

    const row = await env.FORUM_DB.prepare(
      'SELECT * FROM feedback WHERE id = ?',
    )
      .bind(body.id)
      .first<Record<string, unknown>>();
    expect(row).not.toBeNull();
    expect(row!.message).toBe(body.message);
    expect(row!.user_id).toBe('cb-fb-tester');
    expect(row!.build_stamp).toBe('1783956142'); // pins the exact binary
    expect(row!.logs).toBe(body.logs);
  });

  it('stores an attached screenshot in R2, out of the PUBLIC media namespace', async () => {
    const body = report({ has_screenshot: true, screenshot_base64: PNG_B64 });
    const res = await post('cb-fb-shot', body);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ id: body.id, screenshot: true });

    const object = await env.FORUM_MEDIA.head(`feedback/${body.id}.png`);
    expect(object).not.toBeNull();

    // A screenshot can show a loved one's care data. The PUBLIC /media route
    // serves ONLY avatars — it must not hand this out.
    const leaked = await SELF.fetch(`${ORIGIN}/media/feedback/${body.id}.png`);
    expect(leaked.status).toBe(404);
    await leaked.arrayBuffer();
  });

  it('is IDEMPOTENT on the app-minted id — the phone retries from its outbox', async () => {
    const body = report({ message: 'first' });
    expect((await post('cb-fb-retry', body)).status).toBe(200);
    // The phone never saw the 200 (dropped response) and re-sends the same id.
    expect(
      (await post('cb-fb-retry', { ...body, message: 'first (retried)' }))
        .status,
    ).toBe(200);

    const rows = await env.FORUM_DB.prepare(
      'SELECT * FROM feedback WHERE id = ?',
    )
      .bind(body.id)
      .all();
    expect(rows.results).toHaveLength(1); // one report, not two
    expect(
      (rows.results[0] as Record<string, unknown>).message,
    ).toBe('first (retried)');
  });

  it('rejects an empty message and a malformed id', async () => {
    expect((await post('cb-fb-bad', report({ message: '   ' }))).status).toBe(
      400,
    );
    expect(
      (await post('cb-fb-bad', report({ id: '../../etc/passwd' }))).status,
    ).toBe(400);
  });
});

describe('GET /api/v1/feedback (operator triage)', () => {
  it('a plain tester CANNOT read reports — they carry other people’s PHI', async () => {
    await post('cb-fb-author', report({ message: 'private care details' }));

    // Even a bootstrapped, legitimate caregiver: filing ≠ reading.
    await authedFetch('/api/v1/profiles/bootstrap', {
      method: 'POST',
      sub: 'cb-fb-nosy',
    });
    const res = await authedFetch('/api/v1/feedback', { sub: 'cb-fb-nosy' });
    expect(res.status).toBe(403);
  });

  it('an admin sees the triage queue, newest first', async () => {
    await makeAdmin('cb-fb-admin');
    await post('cb-fb-t1', report({ message: 'older' }));
    await new Promise((r) => setTimeout(r, 5));
    await post('cb-fb-t2', report({ message: 'newer' }));

    const res = await authedFetch('/api/v1/feedback', { sub: 'cb-fb-admin' });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      feedback: Array<{ message: string; has_screenshot: boolean }>;
    };
    expect(body.feedback).toHaveLength(2);
    expect(body.feedback[0].message).toBe('newer');
    expect(body.feedback[1].message).toBe('older');
  });

  it('an admin can pull a report’s screenshot; a tester cannot', async () => {
    await makeAdmin('cb-fb-admin2');
    const body = report({ has_screenshot: true, screenshot_base64: PNG_B64 });
    await post('cb-fb-shot2', body);

    const denied = await authedFetch(`/api/v1/feedback/${body.id}/screenshot`, {
      sub: 'cb-fb-shot2', // the author themselves — still not an admin
    });
    expect(denied.status).toBe(403);
    await denied.arrayBuffer();

    const allowed = await authedFetch(
      `/api/v1/feedback/${body.id}/screenshot`,
      { sub: 'cb-fb-admin2' },
    );
    expect(allowed.status).toBe(200);
    expect(allowed.headers.get('content-type')).toBe('image/png');
    expect(allowed.headers.get('cache-control')).toContain('no-store');
    await allowed.arrayBuffer();
  });
});

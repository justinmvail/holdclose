import { SELF, env } from 'cloudflare:test';
import { Hono } from 'hono';
import { sign } from 'hono/jwt';
import { describe, expect, it } from 'vitest';

import { auth, type AuthBindings, type AuthVariables } from '../src/middleware/auth';

const SECRET = env.FORUM_JWT_SECRET;
const ORIGIN = 'https://forum.careblazers.local';

const nowSec = () => Math.floor(Date.now() / 1000);

async function mintToken(
  claims: { sub: string; iat?: number; exp?: number },
  secret: string = SECRET,
) {
  const iat = claims.iat ?? nowSec();
  const exp = claims.exp ?? iat + 3600;
  return sign({ sub: claims.sub, iat, exp }, secret, 'HS256');
}

describe('public routes (no auth)', () => {
  it('GET /health is reachable without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/health`);
    expect(res.status).toBe(200);
  });

  it('GET /api/v1/posts is reachable without a token', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts`);
    expect(res.status).toBe(200);
  });
});

describe('auth middleware on /api/v1/*', () => {
  it('POST /api/v1/posts without a token returns 401', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/posts`, { method: 'POST' });
    expect(res.status).toBe(401);
  });

  it('returns 401 when the Authorization header is missing', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/me`);
    expect(res.status).toBe(401);
  });

  it('returns 401 when the Authorization header is malformed', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/me`, {
      headers: { Authorization: 'Token abc.def.ghi' },
    });
    expect(res.status).toBe(401);
  });

  it('returns 401 when the bearer token is not a JWT', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/me`, {
      headers: { Authorization: 'Bearer not-a-jwt' },
    });
    expect(res.status).toBe(401);
  });

  it('returns 401 when the token is signed with the wrong secret', async () => {
    const token = await mintToken({ sub: 'cb-user-1' }, 'a-different-secret');
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/me`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
    expect(res.headers.get('Token-Expired')).toBeNull();
  });

  it('returns 401 + Token-Expired: true when the token is expired', async () => {
    const iat = nowSec() - 7200;
    const exp = nowSec() - 3600;
    const token = await mintToken({ sub: 'cb-user-1', iat, exp });
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/me`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
    expect(res.headers.get('Token-Expired')).toBe('true');
  });

  it('lets a valid token through to the next handler (404 here — no route)', async () => {
    const token = await mintToken({ sub: 'cb-user-1' });
    const res = await SELF.fetch(`${ORIGIN}/api/v1/__auth_probe`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(404);
    expect(res.headers.get('Token-Expired')).toBeNull();
  });
});

describe('auth middleware unit — sets userId', () => {
  function makeProbeApp() {
    const probe = new Hono<{ Bindings: AuthBindings; Variables: AuthVariables }>();
    probe.use('*', auth());
    probe.get('/whoami', (c) => c.json({ userId: c.get('userId') }));
    return probe;
  }

  it('sets c.get("userId") from the sub claim on a valid token', async () => {
    const token = await mintToken({ sub: 'cb-user-42' });
    const res = await makeProbeApp().request(
      '/whoami',
      { headers: { Authorization: `Bearer ${token}` } },
      { FORUM_JWT_SECRET: SECRET },
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ userId: 'cb-user-42' });
  });

  it('rejects a valid signature whose sub claim is empty', async () => {
    const token = await mintToken({ sub: '' });
    const res = await makeProbeApp().request(
      '/whoami',
      { headers: { Authorization: `Bearer ${token}` } },
      { FORUM_JWT_SECRET: SECRET },
    );
    expect(res.status).toBe(401);
  });
});

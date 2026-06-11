import { SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';

const ORIGIN = 'https://forum.careblazers.local';

describe('GET /join/:token (public invite landing page)', () => {
  it('renders the deep link but does NOT echo the raw token in the body',
      async () => {
    const token = 'abc123XYZ_-token';
    const response = await SELF.fetch(`${ORIGIN}/join/${token}`);

    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toContain('text/html');

    const body = await response.text();
    // The big "Open in Careblazers" button hands off to the app.
    expect(body).toContain(`careblazers://join/${token}`);
    // 2026-06-11: the token must appear ONLY inside that href — no
    // copy/paste block that lingers in screenshots or screen-shares.
    expect(body.split(token)).toHaveLength(2);
    expect(body).toContain('care circle');
    // The page sets expectations for the in-app confirmation gate.
    expect(body).toContain('confirm');
  });

  it('is public — no Authorization header required (200, not 401)', async () => {
    const response = await SELF.fetch(`${ORIGIN}/join/sometoken`);
    expect(response.status).toBe(200);
  });
});

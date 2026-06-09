import { SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';

const ORIGIN = 'https://forum.careblazers.local';

describe('GET /join/:token (public invite landing page)', () => {
  it('renders the deep link + raw token for a given token', async () => {
    const token = 'abc123XYZ_-token';
    const response = await SELF.fetch(`${ORIGIN}/join/${token}`);

    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toContain('text/html');

    const body = await response.text();
    // The big "Open in Careblazers" button hands off to the app.
    expect(body).toContain(`careblazers://join/${token}`);
    // The raw token is shown as a copy/paste fallback.
    expect(body).toContain(token);
    expect(body).toContain('care circle');
  });

  it('is public — no Authorization header required (200, not 401)', async () => {
    const response = await SELF.fetch(`${ORIGIN}/join/sometoken`);
    expect(response.status).toBe(200);
  });
});

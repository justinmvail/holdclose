import { SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';

const ORIGIN = 'https://forum.holdclose.local';

describe('GET /terms (public Terms of Service page)', () => {
  it('serves the terms HTML with the required commitments', async () => {
    const response = await SELF.fetch(`${ORIGIN}/terms`);

    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toContain('text/html');

    const body = await response.text();
    expect(body).toContain('Holdclose Terms of Service');
    expect(body).toContain('Juno Code Studio');
    expect(body).toContain('JCSV One LLC');
    expect(body).toContain('support@holdclose.care');
    expect(body).toContain('Last updated: July 8, 2026');
    // The store-review-critical clauses.
    expect(body).toContain('personal, non-commercial');
    expect(body).toContain('not a medical device');
    expect(body).toContain('medical advice, diagnosis, or treatment');
    expect(body).toContain('recommend medication doses');
    // AI honesty: generated content may be wrong; decisions stay human.
    expect(body).toContain('AI-generated content');
    expect(body).toMatch(/decisions about your loved one.+s care remain with you/);
    expect(body).toContain('clinicians');
    expect(body).toContain('Termination');
    expect(body).toContain('limitation of liability');
    expect(body).toContain('South Carolina');
  });

  it('is public — no Authorization header required (200, not 401)', async () => {
    const response = await SELF.fetch(`${ORIGIN}/terms`);
    expect(response.status).toBe(200);
  });
});

describe('GET /privacy (public Privacy Policy page)', () => {
  it('serves the privacy HTML with the required disclosures', async () => {
    const response = await SELF.fetch(`${ORIGIN}/privacy`);

    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toContain('text/html');

    const body = await response.text();
    expect(body).toContain('Holdclose Privacy Policy');
    expect(body).toContain('Juno Code Studio');
    expect(body).toContain('support@holdclose.care');
    expect(body).toContain('Last updated: July 8, 2026');
    // The data-handling disclosures the sign-in link promises.
    expect(body).toContain('on your device by default');
    expect(body).toContain('Care Circle');
    expect(body).toMatch(/Google account identifier .*sub.*, email address/);
    expect(body).toContain('documents you scan');
    expect(body).toContain('coach chat');
    expect(body).toContain('consent toggles');
    expect(body).toContain('do not sell your personal data');
    expect(body).toContain('do not show ads');
    expect(body).toContain('deletion of your account');
    expect(body).toContain('children under 13');
  });

  it('is public — no Authorization header required (200, not 401)', async () => {
    const response = await SELF.fetch(`${ORIGIN}/privacy`);
    expect(response.status).toBe(200);
  });
});

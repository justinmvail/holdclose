import { Hono } from 'hono';
import { describe, expect, it } from 'vitest';

import { handleAppError } from '../src/index';

const ORIGIN = 'https://forum.holdclose.local';

// app.onError is the last-resort boundary: whatever a route lets escape
// must come back as a GENERIC `{error: 'internal'}` 500 — never the real
// error message, stack frames, or SQL. We pin that property on the
// EXPORTED handler against a deliberately-throwing route, rather than
// depending on a specific route's input-validation gap (those gaps are
// exactly what we keep closing — the previous Infinity vector now
// returns a clean 400). This stays meaningful as routes harden.
describe('handleAppError (unhandled error boundary)', () => {
  function appThatThrows(thrown: unknown) {
    const app = new Hono();
    app.onError(handleAppError);
    app.get('/boom', () => {
      throw thrown;
    });
    return app;
  }

  it('answers an escaping route error with a generic internal 500', async () => {
    const app = appThatThrows(
      new Error(
        'D1_ERROR: NOT NULL constraint failed: circles.name; token=abc123',
      ),
    );
    const res = await app.request(`${ORIGIN}/boom`);
    expect(res.status).toBe(500);

    const text = await res.text();
    expect(JSON.parse(text)).toEqual({ error: 'internal' });
    // The real message — SQL, the D1_ prefix, the word "Error", any stack,
    // any embedded secret — must not appear in the response body.
    expect(text).not.toMatch(/D1_|constraint|SQL|stack|Error:|abc123/i);
  });
});

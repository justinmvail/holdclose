import { Hono } from 'hono';

import { auth, type AuthBindings, type AuthVariables } from './middleware/auth';
import { authRouter } from './routes/auth';
import { chatRouter, type ChatBindings } from './routes/chat';
import { circlesRouter } from './routes/circles';
import { commentsRouter } from './routes/comments';
import { documentsRouter } from './routes/documents';
import { joinRouter } from './routes/join';
import { postsRouter } from './routes/posts';
import { profilesRouter } from './routes/profiles';
import { reportsRouter } from './routes/reports';
import { syncRouter } from './routes/sync';
import { votesRouter } from './routes/votes';
import { handleScheduled, type WatchdogEnv } from './watchdog';
import type { Context } from 'hono';

export type Bindings = AuthBindings &
  ChatBindings & {
  FORUM_DB: D1Database;
  FORUM_MEDIA: R2Bucket;
  // R2 bucket holding caregiver document scans (emergency card / POA / ID
  // images) so they survive a reinstall and sync across the care circle.
  DOC_BLOBS: R2Bucket;
  R2_PUBLIC_URL: string;
  // Allowed Google OAuth audience(s) for POST /api/v1/auth/google. Single
  // value = the Web client id; may be a comma-separated list.
  GOOGLE_CLIENT_ID: string;
};

export type Variables = AuthVariables;

const app = new Hono<{ Bindings: Bindings; Variables: Variables }>();

// Last-resort error boundary. Anything a route or middleware lets escape
// (D1 failures, JWKS fetch outages, deliberate rethrows from the auth
// layers) lands here — including errors thrown inside the sub-app mounted
// below, which bubble up to the parent handler. Log the real error
// server-side; the response body stays generic so internals (stack
// frames, SQL text, token contents) never reach a client. Exported so a
// test can pin the genericity property without depending on a specific
// route's validation gap as the throw vector.
export function handleAppError(err: Error, c: Context): Response {
  console.error('unhandled error', err);
  return c.json({ error: 'internal' }, 500);
}

app.onError(handleAppError);

app.get('/health', (c) => c.json({ status: 'ok' }));

// Public care-circle invite landing page. Mounted at the WORKER ROOT (NOT
// under /api/v1) and intentionally EXEMPT from the forum JWT middleware —
// it's a shareable web page the invited caregiver opens from a text link,
// like /auth/google's pre-auth handshake. It just renders the token from
// the path + offers a `holdclose://join/<token>` deep link into the app.
app.route('/join', joinRouter());

const api = new Hono<{ Bindings: Bindings; Variables: Variables }>();

// Posts + comments routers mount BEFORE the global auth middleware
// so the GET list + detail + thread reads remain read-anonymous per
// BUILD_SPEC §13. Each router applies route-level auth() to its
// write endpoints itself.
api.route('/', commentsRouter());
api.route('/posts', postsRouter());

// Google sign-in bootstrap also mounts BEFORE the global forum JWT auth
// middleware: it's the identity-establishing handshake (verifying a Google
// ID token), so there's no forum JWT to require yet.
api.route('/auth', authRouter());

api.use('*', auth());

api.route('/profiles', profilesRouter());
api.route('/circles', circlesRouter());
api.route('/reports', reportsRouter());
api.route('/sync', syncRouter());
// LLM coach proxy. Behind the forum JWT (mounted after auth() above) so
// every call is tied to a real account — the chokepoint where per-user
// quotas + the global daily spend cap are enforced and token usage is
// logged. The inference host's API key lives only here, never on-device.
api.route('/chat', chatRouter());
api.route('/documents', documentsRouter());
api.route('/votes', votesRouter());

app.route('/api/v1', api);

export default {
  fetch: app.fetch,
  async scheduled(
    _controller: ScheduledController,
    env: Bindings & WatchdogEnv,
    ctx: ExecutionContext,
  ): Promise<void> {
    // The watchdog can take a few seconds (GraphQL + Resend round
    // trips); waitUntil keeps the scheduled invocation alive past
    // the synchronous return so Workers doesn't kill it mid-flight.
    ctx.waitUntil(handleScheduled(env));
  },
};

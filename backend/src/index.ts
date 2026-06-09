import { Hono } from 'hono';

import { auth, type AuthBindings, type AuthVariables } from './middleware/auth';
import { authRouter } from './routes/auth';
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

export type Bindings = AuthBindings & {
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

app.get('/health', (c) => c.json({ status: 'ok' }));

// Public care-circle invite landing page. Mounted at the WORKER ROOT (NOT
// under /api/v1) and intentionally EXEMPT from the forum JWT middleware —
// it's a shareable web page the invited caregiver opens from a text link,
// like /auth/google's pre-auth handshake. It just renders the token from
// the path + offers a `careblazers://join/<token>` deep link into the app.
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

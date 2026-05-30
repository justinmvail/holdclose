import { Hono } from 'hono';

import { auth, type AuthBindings, type AuthVariables } from './middleware/auth';
import { profilesRouter } from './routes/profiles';

export type Bindings = AuthBindings & {
  FORUM_DB: D1Database;
  FORUM_MEDIA: R2Bucket;
  R2_PUBLIC_URL: string;
};

export type Variables = AuthVariables;

const app = new Hono<{ Bindings: Bindings; Variables: Variables }>();

app.get('/health', (c) => c.json({ status: 'ok' }));

const api = new Hono<{ Bindings: Bindings; Variables: Variables }>();

// Read-anonymous endpoint per BUILD_SPEC §13 — registered before the auth
// middleware so the handler short-circuits the request chain. Phase 13.5
// replaces this stub with the real feed handler.
api.get('/posts', (c) => c.json({ posts: [] }));

api.use('*', auth());

api.route('/profiles', profilesRouter());

app.route('/api/v1', api);

export default app;

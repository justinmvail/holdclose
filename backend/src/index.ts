import { Hono } from 'hono';

import { auth, type AuthBindings, type AuthVariables } from './middleware/auth';
import { commentsRouter } from './routes/comments';
import { postsRouter } from './routes/posts';
import { profilesRouter } from './routes/profiles';
import { votesRouter } from './routes/votes';

export type Bindings = AuthBindings & {
  FORUM_DB: D1Database;
  FORUM_MEDIA: R2Bucket;
  R2_PUBLIC_URL: string;
};

export type Variables = AuthVariables;

const app = new Hono<{ Bindings: Bindings; Variables: Variables }>();

app.get('/health', (c) => c.json({ status: 'ok' }));

const api = new Hono<{ Bindings: Bindings; Variables: Variables }>();

// Posts + comments routers mount BEFORE the global auth middleware
// so the GET list + detail + thread reads remain read-anonymous per
// BUILD_SPEC §13. Each router applies route-level auth() to its
// write endpoints itself.
api.route('/', commentsRouter());
api.route('/posts', postsRouter());

api.use('*', auth());

api.route('/profiles', profilesRouter());
api.route('/votes', votesRouter());

app.route('/api/v1', api);

export default app;

import { Hono } from 'hono';

export type Bindings = {
  FORUM_DB: D1Database;
  FORUM_MEDIA: R2Bucket;
};

const app = new Hono<{ Bindings: Bindings }>();

app.get('/health', (c) => c.json({ status: 'ok' }));

export default app;

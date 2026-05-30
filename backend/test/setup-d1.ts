import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll } from 'vitest';

declare module 'cloudflare:test' {
  interface ProvidedEnv {
    FORUM_DB: D1Database;
    FORUM_MEDIA: R2Bucket;
    TEST_MIGRATIONS: import('cloudflare:test').D1Migration[];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.FORUM_DB, env.TEST_MIGRATIONS);
});

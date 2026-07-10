import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll } from 'vitest';

declare module 'cloudflare:test' {
  interface ProvidedEnv {
    FORUM_DB: D1Database;
    FORUM_MEDIA: R2Bucket;
    DOC_BLOBS: R2Bucket;
    FORUM_JWT_SECRET: string;
    R2_PUBLIC_URL: string;
    GOOGLE_CLIENT_ID: string;
    // IAP receipt-verification creds (billing routes). Left UNSET in the
    // default test env so the misconfigured-platform case is exercisable; the
    // billing route tests inject a FakeVerifier and never depend on real
    // Apple/Google credentials.
    APPLE_ISSUER_ID?: string;
    APPLE_KEY_ID?: string;
    APPLE_PRIVATE_KEY?: string;
    APPLE_BUNDLE_ID?: string;
    GOOGLE_PLAY_SA_EMAIL?: string;
    GOOGLE_PLAY_SA_PRIVATE_KEY?: string;
    GOOGLE_PLAY_PACKAGE?: string;
    TEST_MIGRATIONS: import('cloudflare:test').D1Migration[];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.FORUM_DB, env.TEST_MIGRATIONS);
});

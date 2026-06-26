import path from 'node:path';

import {
  defineWorkersConfig,
  readD1Migrations,
} from '@cloudflare/vitest-pool-workers/config';

export default defineWorkersConfig(async () => {
  const migrationsPath = path.join(__dirname, 'drizzle');
  const migrations = await readD1Migrations(migrationsPath);

  return {
    test: {
      setupFiles: ['./test/setup-d1.ts'],
      poolOptions: {
        workers: {
          wrangler: { configPath: './wrangler.toml' },
          miniflare: {
            compatibilityFlags: ['nodejs_compat'],
            bindings: {
              TEST_MIGRATIONS: migrations,
              FORUM_JWT_SECRET: 'test-forum-jwt-secret',
              R2_PUBLIC_URL: 'https://media.holdclose.test',
              GOOGLE_CLIENT_ID: 'test-google-web-client-id.apps.googleusercontent.com',
              // Chat coach (/api/v1/chat). The key is a secret in prod; set
              // it here so the route isn't "misconfigured" under test. Caps
              // are pinned to known values so the quota/circuit-breaker
              // tests are deterministic.
              CEREBRAS_API_KEY: 'test-cerebras-key',
              CEREBRAS_BASE_URL: 'https://api.cerebras.ai/v1',
              CHAT_MODEL: 'gpt-oss-120b',
              CHAT_MAX_INPUT_CHARS: '48000',
              CHAT_MAX_OUTPUT_TOKENS: '1024',
              CHAT_USER_DAILY_TOKENS: '300000',
              CHAT_GLOBAL_FLOOR_MICROS: '5000000',
              CHAT_PER_USER_BUDGET_MICROS: '100000',
            },
          },
        },
      },
    },
  };
});

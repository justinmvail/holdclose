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
              // AI coach + scan extract (Cloudflare Workers AI, OpenAI-
              // compatible endpoint). Token + account are secret/var in
              // prod; set here so the routes aren't "misconfigured" under
              // test. CF_AI_BASE_URL is overridden to a mockable host so the
              // fetch interceptor stands in for Workers AI. Caps are pinned
              // so the quota/circuit-breaker tests are deterministic.
              CF_AI_API_TOKEN: 'test-cf-ai-token',
              CLOUDFLARE_ACCOUNT_ID: 'test-account',
              CF_AI_BASE_URL: 'https://ai.holdclose.test/v1',
              CHAT_MODEL: '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
              EXTRACT_MODEL: '@cf/meta/llama-3.2-11b-vision-instruct',
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

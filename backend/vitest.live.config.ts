import { defineConfig } from 'vitest/config';

// LIVE-BACKEND integration suite — runs in PLAIN NODE (no workers pool, no
// miniflare) and drives a DEPLOYED Worker over real HTTPS. Kept in a
// separate config so `npm test` (the hermetic vitest-pool-workers suite)
// never picks these up: they cost real Workers-AI inference, write real
// rows to the dev D1/R2, and need network + the dev FORUM_JWT_SECRET.
//
//   npm run test:live                 # → holdclose-forum-dev (default)
//   LIVE_BASE_URL=<url> npm run test:live
//
// See test-live/live-backend.test.ts for the auth model + safety rails.
export default defineConfig({
  test: {
    include: ['test-live/**/*.test.ts'],
    // One file, sequential tests — the flows build on each other
    // (bootstrap → circle → invite → sync → …). No retries: a flake
    // against the real edge is signal, not noise.
    fileParallelism: false,
    // Real inference + cold starts can be slow.
    testTimeout: 90_000,
    hookTimeout: 30_000,
  },
});

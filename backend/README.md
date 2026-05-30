# Careblazers Forum Backend

Cloudflare Workers backend for the Careblazers caregiver forum
(BUILD_SPEC.md §13 / TASKS.md Phase 13). Single-board Reddit-style
forum with threaded comments, hosted on Cloudflare for cost-of-scale
and zero-egress. The Flutter app talks to this Worker via Dio + JWTs
minted off the existing Apple/Google sign-in (Phase 13.9 onwards).

## Stack

- **Cloudflare Workers** — compute (TypeScript)
- **Cloudflare D1** — SQLite-at-edge (`FORUM_DB` binding)
- **Cloudflare R2** — object storage for avatars + post images
  (`FORUM_MEDIA` binding)
- **Hono** — adapter-portable web framework
- **Vitest** + `@cloudflare/vitest-pool-workers` — Worker-side tests
  running against miniflare's in-process D1/R2 emulators

## Layout

```
backend/
  package.json
  tsconfig.json
  wrangler.toml         ← Worker config + D1/R2 bindings
  vitest.config.ts
  src/
    index.ts            ← Hono app entry (currently: GET /health)
  test/
    health.test.ts      ← smoke test for /health
```

Subsequent Phase 13 iters add `src/db/schema.ts` (Drizzle),
`src/middleware/auth.ts`, and route modules under `src/routes/`.

## Local dev

```bash
cd backend
npm install
npm run dev          # wrangler dev — serves on http://127.0.0.1:8787
```

`wrangler dev` runs the Worker against miniflare's in-process D1/R2
emulators by default, so no remote Cloudflare resources are required
to iterate locally. Smoke-check:

```bash
curl http://127.0.0.1:8787/health
# → {"status":"ok"}
```

## Tests

```bash
npm test             # vitest run (one-shot)
npm run test:watch   # vitest watch mode
npm run typecheck    # tsc --noEmit
```

Vitest spins up an isolated miniflare runtime per test file and
exposes the Worker via `SELF.fetch(...)` from `cloudflare:test`. D1
and R2 bindings declared in `wrangler.toml` are auto-emulated — no
extra setup needed.

## Deploy

```bash
# One-time setup (run from the backend/ directory):
wrangler login
wrangler d1 create careblazers-forum
#   → paste the returned UUID into wrangler.toml's database_id
wrangler r2 bucket create careblazers-forum-media
wrangler secret put FORUM_JWT_SECRET   # Phase 13.3 — auth middleware

# Deploy:
npm run deploy       # wrangler deploy
```

Migrations (Phase 13.2 onward) run via `wrangler d1 migrations apply
FORUM_DB --remote` after `drizzle-kit generate` produces new SQL
under `drizzle/`.

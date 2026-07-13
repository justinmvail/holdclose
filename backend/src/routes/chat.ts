import { and, gte, sql } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import { llmUsage, profiles } from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

// Minimal shape of the native Workers AI binding we use. With `stream: true`
// a text model returns a ReadableStream of SSE bytes (`data: {"response":…}`)
// — exactly what the parser below already reads. Typed locally so we don't
// pin a specific @cloudflare/workers-types `Ai` signature.
type WorkersAiBinding = {
  run(
    model: string,
    options: Record<string, unknown>,
  ): Promise<ReadableStream<Uint8Array>>;
};

export type ChatBindings = AuthBindings & {
  FORUM_DB: D1Database;
  // Inference runs on Cloudflare Workers AI (the loved one's data stays on
  // Cloudflare's network — the same infra hosting the Worker + D1 + R2 — and
  // never goes to a separate AI vendor). The deployed worker uses the native
  // `AI` binding (no runtime token — see `[env.dev.ai]` in wrangler.toml).
  // CF_AI_API_TOKEN + CLOUDFLARE_ACCOUNT_ID remain a REST fallback for an
  // environment configured with a token instead (OpenAI-compatible endpoint
  // /client/v4/accounts/<id>/ai/v1/chat/completions).
  AI?: WorkersAiBinding;
  CF_AI_API_TOKEN?: string;
  CLOUDFLARE_ACCOUNT_ID?: string;
  CF_AI_BASE_URL?: string;
  CHAT_MODEL?: string;
  // Caps (all optional — defaults below). Strings because Worker vars
  // arrive as strings.
  CHAT_MAX_INPUT_CHARS?: string;
  CHAT_MAX_OUTPUT_TOKENS?: string;
  CHAT_USER_DAILY_TOKENS?: string;
  CHAT_GLOBAL_FLOOR_MICROS?: string;
  CHAT_PER_USER_BUDGET_MICROS?: string;
};

export type ChatVariables = AuthVariables;

type Db = ReturnType<typeof drizzle>;

// Cost proxy in MICRO-DOLLARS per token ($1 = 1_000_000 micros). Workers
// AI actually bills in "neurons", not tokens, so these are a rough proxy
// that keeps the spend-cap circuit-breaker meaningful; tune them to your
// Workers AI plan's effective per-token cost. Kept token-based so the
// per-user daily-token quota and the llmUsage table stay unchanged.
const INPUT_MICROS_PER_TOKEN = 0.35;
const OUTPUT_MICROS_PER_TOKEN = 0.75;

// Defaults if the corresponding Worker var is unset. See README → "Chat
// cost controls". The global floor + per-user budget together implement
// "alpha = $5/day, prod = a ratio of users": cap = max(floor, budget ×
// users), so with a handful of users the $5 floor wins automatically and
// no separate alpha flag is needed.
const DEFAULTS = {
  model: '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
  maxInputChars: 48_000, // ~12K tokens of prompt; blocks payload-stuffing
  maxOutputTokens: 1024, // one call can't generate forever
  userDailyTokens: 300_000, // ≈ $0.10/user/day hard ceiling
  globalFloorMicros: 5_000_000, // $5.00/day floor (alpha)
  perUserBudgetMicros: 100_000, // $0.10/user/day → the prod ratio
} as const;

const num = (v: string | undefined, fallback: number): number => {
  if (v === undefined) return fallback;
  const parsed = Number(v);
  return Number.isFinite(parsed) ? parsed : fallback;
};

/** Midnight UTC of the current day, as a Date (drizzle compares as ms). */
function startOfUtcDay(now: number): Date {
  return new Date(Math.floor(now / 86_400_000) * 86_400_000);
}

function costMicros(promptTokens: number, completionTokens: number): number {
  return Math.round(
    promptTokens * INPUT_MICROS_PER_TOKEN +
      completionTokens * OUTPUT_MICROS_PER_TOKEN,
  );
}

/** Rough token estimate (~4 chars/token) for the usage fallback when the
 * host doesn't return a usage block. Deliberately conservative (rounds up)
 * so an un-metered call can't slip under the caps for free. */
const estimateTokens = (text: string): number => Math.ceil(text.length / 4);

export function chatRouter() {
  const router = new Hono<{ Bindings: ChatBindings; Variables: ChatVariables }>();

  router.post('/', async (c) => {
    const userId = c.get('userId');
    const env = c.env;

    if (!env.AI && (!env.CF_AI_API_TOKEN || !env.CLOUDFLARE_ACCOUNT_ID)) {
      return c.json({ error: 'server_misconfigured' }, 500);
    }

    // --- Parse + size-cap the request -----------------------------------
    let system: string;
    let user: string;
    let feature = 'chat';
    try {
      const body = (await c.req.json()) as {
        system?: unknown;
        user?: unknown;
        feature?: unknown;
      };
      if (typeof body.system !== 'string' || typeof body.user !== 'string') {
        return c.json({ error: 'bad_request' }, 400);
      }
      system = body.system;
      user = body.user;
      // Optional accounting tag (e.g. 'chat' | 'recap'). Clamp length so
      // it can't be used to stuff the usage table; default to 'chat'.
      if (typeof body.feature === 'string' && body.feature.length <= 32) {
        feature = body.feature;
      }
    } catch {
      return c.json({ error: 'bad_request' }, 400);
    }

    const maxInputChars = num(env.CHAT_MAX_INPUT_CHARS, DEFAULTS.maxInputChars);
    if (system.length + user.length > maxInputChars) {
      // 413: the client should not retry the same oversized prompt.
      return c.json({ error: 'prompt_too_large' }, 413);
    }

    const db = drizzle(env.FORUM_DB);
    const dayStart = startOfUtcDay(Date.now());

    // --- Layer 4: per-user daily token quota ----------------------------
    const userDailyTokens = num(
      env.CHAT_USER_DAILY_TOKENS,
      DEFAULTS.userDailyTokens,
    );
    const [usedRow] = await db
      .select({
        tokens: sql<number>`coalesce(sum(${llmUsage.promptTokens} + ${llmUsage.completionTokens}), 0)`,
      })
      .from(llmUsage)
      .where(
        and(
          sql`${llmUsage.userId} = ${userId}`,
          gte(llmUsage.createdAt, dayStart),
        ),
      );
    if ((usedRow?.tokens ?? 0) >= userDailyTokens) {
      // 429: friendly "you've hit today's coach limit" — retry tomorrow.
      return c.json({ error: 'daily_limit' }, 429);
    }

    // --- Layer 5: global daily spend circuit breaker --------------------
    const floor = num(env.CHAT_GLOBAL_FLOOR_MICROS, DEFAULTS.globalFloorMicros);
    const perUser = num(
      env.CHAT_PER_USER_BUDGET_MICROS,
      DEFAULTS.perUserBudgetMicros,
    );
    const [{ count: userCount }] = await db
      .select({ count: sql<number>`count(*)` })
      .from(profiles);
    const [spentRow] = await db
      .select({
        micros: sql<number>`coalesce(sum(${llmUsage.costMicros}), 0)`,
      })
      .from(llmUsage)
      .where(gte(llmUsage.createdAt, dayStart));
    const dailyCapMicros = Math.max(floor, perUser * (userCount ?? 0));
    if ((spentRow?.micros ?? 0) >= dailyCapMicros) {
      // 503: org-wide ceiling hit — the coach "rests" rather than bill on.
      return c.json({ error: 'capacity' }, 503);
    }

    // --- Call Workers AI (native binding preferred; REST fallback) ------
    const model = env.CHAT_MODEL ?? DEFAULTS.model;
    const maxOutputTokens = num(
      env.CHAT_MAX_OUTPUT_TOKENS,
      DEFAULTS.maxOutputTokens,
    );
    const messages = [
      { role: 'system', content: system },
      { role: 'user', content: user },
    ];

    // The deployed worker uses the native `AI` binding (no runtime token);
    // the REST branch stays a fallback for an env configured with
    // CF_AI_API_TOKEN instead. Both stream SSE the loop below parses the same
    // way — the binding emits `data: {"response":…}`, the OpenAI-compatible
    // endpoint emits `data: {"choices":[{"delta":{"content":…}}]}` (+ usage).
    let upstreamBody: ReadableStream<Uint8Array>;
    if (env.AI) {
      try {
        upstreamBody = await env.AI.run(model, {
          messages,
          stream: true,
          max_tokens: maxOutputTokens,
        });
      } catch {
        return c.json({ error: 'coach_unavailable' }, 502);
      }
    } else {
      const baseUrl =
        env.CF_AI_BASE_URL ??
        `https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}/ai/v1`;
      const upstream = await fetch(`${baseUrl}/chat/completions`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.CF_AI_API_TOKEN}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model,
          stream: true,
          max_tokens: maxOutputTokens,
          stream_options: { include_usage: true },
          messages,
        }),
      });
      if (!upstream.ok || !upstream.body) {
        return c.json({ error: 'coach_unavailable' }, 502);
      }
      upstreamBody = upstream.body;
    }

    // --- Re-emit a vendor-neutral SSE the app parses, and log usage -----
    // Contract (mirrors the shim's simple shape): `data: {"text":"…"}` per
    // delta, then `data: [DONE]`. Errors mid-stream: `data: {"error":"…"}`.
    // The vendor's wire format never reaches the client (keeps the model
    // invisible per the UI rule, and decouples the app from the host).
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const reader = upstreamBody.getReader();

    let promptTokens = 0;
    let completionTokens = 0;
    let sawUsage = false;
    let emittedChars = 0;
    let buffer = '';

    let usageLogged = false;
    const logUsage = async () => {
      // Exactly once per request: [finish] and cancel() can both fire (a
      // client that hangs up right as the model finishes), and double-billing
      // a caregiver's quota would be worse than missing the edge case.
      if (usageLogged) return;
      usageLogged = true;
      const pt = sawUsage ? promptTokens : estimateTokens(system + user);
      const ct = sawUsage ? completionTokens : estimateTokens(' '.repeat(emittedChars));
      await db.insert(llmUsage).values({
        userId,
        model,
        feature,
        promptTokens: pt,
        completionTokens: ct,
        costMicros: costMicros(pt, ct),
      });
    };

    // End the response: meter the call, emit our own terminator, close.
    //
    // Termination is the subtle part, and getting it wrong cost us the cost
    // controls (live suite, 2026-07-13). The native `env.AI` binding does NOT
    // end its stream the way the REST endpoint does: it sends the OpenAI-shaped
    // chunks, then a `finish_reason: "stop"` delta, then a final usage chunk —
    // and then goes SILENT FOREVER. No `[DONE]`, no close. Waiting on the
    // reader's `done` therefore hung the Worker until the runtime killed it
    // ("your Worker's code had hung"), and `logUsage()` — which lived in that
    // unreachable branch — NEVER RAN. `llm_usage` stayed empty on the deploy,
    // and BOTH the per-user daily token quota and the global daily spend cap
    // are computed from that table, so the cost circuit-breaker was silently
    // dead. So we finish on whichever end signal the host actually gives:
    // `[DONE]`, the reader closing, or the model's own completion
    // (`finish_reason` + the usage chunk that trails it).
    let finished = false;
    const finish = (controller: ReadableStreamDefaultController<Uint8Array>) => {
      if (finished) return;
      finished = true;
      // waitUntil keeps the insert alive past the response body closing.
      c.executionCtx.waitUntil(logUsage());
      controller.enqueue(encoder.encode('data: [DONE]\n\n'));
      controller.close();
      // The host's stream may still be open (see above) — drop it.
      void reader.cancel();
    };

    // The model said it stopped (`finish_reason`), but the usage chunk that
    // carries the real token counts arrives in the NEXT read. We wait for it
    // — but only this long, because a host that goes silent must never hang
    // the Worker again. On timeout we finish with estimated tokens (which
    // round up, so an un-metered call can't slip under the caps for free).
    const USAGE_GRACE_MS = 400;
    let sawFinishReason = false;

    /** Read the next upstream chunk. Once the model has signalled completion,
     * never block indefinitely: race the read against the grace timer and
     * report `done` if the host has nothing more to say. */
    const readNext = async (): Promise<
      ReadableStreamReadResult<Uint8Array>
    > => {
      if (!sawFinishReason) return reader.read();
      return Promise.race([
        reader.read(),
        new Promise<ReadableStreamReadResult<Uint8Array>>((resolve) =>
          setTimeout(
            () => resolve({ done: true, value: undefined }),
            USAGE_GRACE_MS,
          ),
        ),
      ]);
    };

    const stream = new ReadableStream<Uint8Array>({
      async pull(controller) {
        const { done, value } = await readNext();
        if (done) {
          finish(controller);
          return;
        }
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          const data = trimmed.slice(5).trim();
          if (data === '') continue;
          // The REST endpoint's end-of-stream sentinel. Authoritative — do
          // NOT wait for the reader to close (see [finish]).
          if (data === '[DONE]') {
            finish(controller);
            return;
          }
          let chunk: {
            // Workers AI native shape: {"response":"…","usage":{…}}.
            response?: string;
            // OpenAI-compatible shape — what the AI binding and the
            // OpenAI-compatible REST endpoint both actually emit:
            // {"choices":[{"delta":{"content":"…"},"finish_reason":null}]}.
            choices?: {
              delta?: { content?: string };
              finish_reason?: string | null;
            }[];
            usage?: {
              prompt_tokens?: number;
              completion_tokens?: number;
            };
          };
          try {
            chunk = JSON.parse(data);
          } catch {
            continue;
          }
          if (chunk.choices?.some((ch) => ch.finish_reason)) {
            sawFinishReason = true;
          }
          if (chunk.usage) {
            sawUsage = true;
            promptTokens = chunk.usage.prompt_tokens ?? promptTokens;
            completionTokens =
              chunk.usage.completion_tokens ?? completionTokens;
          }
          const delta = chunk.response ?? chunk.choices?.[0]?.delta?.content;
          if (delta) {
            emittedChars += delta.length;
            controller.enqueue(
              encoder.encode(`data: ${JSON.stringify({ text: delta })}\n\n`),
            );
          }
          // The model stopped AND we have its real token counts: everything
          // we need has arrived, so end now rather than waiting on a
          // terminator the host may never send.
          if (sawFinishReason && sawUsage) {
            finish(controller);
            return;
          }
        }
      },
      cancel() {
        // Client hung up — still bill what we used, then drop upstream.
        // logUsage is idempotent, so a cancel racing [finish] bills once.
        finished = true;
        c.executionCtx.waitUntil(logUsage());
        void reader.cancel();
      },
    });

    return new Response(stream, {
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
      },
    });
  });

  return router;
}

export type { Db };

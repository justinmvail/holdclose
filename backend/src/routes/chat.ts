import { and, gte, sql } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import { llmUsage, profiles } from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

export type ChatBindings = AuthBindings & {
  FORUM_DB: D1Database;
  // The inference host. Key is a SECRET (`wrangler secret put
  // CEREBRAS_API_KEY`); base URL + model + caps are plain vars so each
  // environment can tune them without a redeploy of code.
  CEREBRAS_API_KEY: string;
  CEREBRAS_BASE_URL?: string;
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

// gpt-oss-120b pricing, expressed in MICRO-DOLLARS per token ($1 =
// 1_000_000 micros). $0.35 / 1M input tokens → 0.35 micro/token; $0.75 /
// 1M output → 0.75 micro/token. If the model or price changes, update
// these two numbers (and the comment in schema.ts's llmUsage table).
const INPUT_MICROS_PER_TOKEN = 0.35;
const OUTPUT_MICROS_PER_TOKEN = 0.75;

// Defaults if the corresponding Worker var is unset. See README → "Chat
// cost controls". The global floor + per-user budget together implement
// "alpha = $5/day, prod = a ratio of users": cap = max(floor, budget ×
// users), so with a handful of users the $5 floor wins automatically and
// no separate alpha flag is needed.
const DEFAULTS = {
  baseUrl: 'https://api.cerebras.ai/v1',
  model: 'gpt-oss-120b',
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

    if (!env.CEREBRAS_API_KEY) {
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

    // --- Call the inference host (OpenAI-compatible, streaming) ---------
    const baseUrl = env.CEREBRAS_BASE_URL ?? DEFAULTS.baseUrl;
    const model = env.CHAT_MODEL ?? DEFAULTS.model;
    const maxOutputTokens = num(
      env.CHAT_MAX_OUTPUT_TOKENS,
      DEFAULTS.maxOutputTokens,
    );

    const upstream = await fetch(`${baseUrl}/chat/completions`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.CEREBRAS_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model,
        stream: true,
        max_tokens: maxOutputTokens,
        stream_options: { include_usage: true },
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user },
        ],
      }),
    });

    if (!upstream.ok || !upstream.body) {
      return c.json({ error: 'coach_unavailable' }, 502);
    }

    // --- Re-emit a vendor-neutral SSE the app parses, and log usage -----
    // Contract (mirrors the shim's simple shape): `data: {"text":"…"}` per
    // delta, then `data: [DONE]`. Errors mid-stream: `data: {"error":"…"}`.
    // The vendor's wire format never reaches the client (keeps the model
    // invisible per the UI rule, and decouples the app from the host).
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const reader = upstream.body.getReader();

    let promptTokens = 0;
    let completionTokens = 0;
    let sawUsage = false;
    let emittedChars = 0;
    let buffer = '';

    const logUsage = async () => {
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

    const stream = new ReadableStream<Uint8Array>({
      async pull(controller) {
        const { done, value } = await reader.read();
        if (done) {
          // Persist usage before closing; waitUntil keeps it alive past
          // the response if the client disconnects early.
          c.executionCtx.waitUntil(logUsage());
          controller.enqueue(encoder.encode('data: [DONE]\n\n'));
          controller.close();
          return;
        }
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          const data = trimmed.slice(5).trim();
          if (data === '' || data === '[DONE]') continue;
          let chunk: {
            choices?: { delta?: { content?: string } }[];
            usage?: { prompt_tokens?: number; completion_tokens?: number };
          };
          try {
            chunk = JSON.parse(data);
          } catch {
            continue;
          }
          if (chunk.usage) {
            sawUsage = true;
            promptTokens = chunk.usage.prompt_tokens ?? promptTokens;
            completionTokens =
              chunk.usage.completion_tokens ?? completionTokens;
          }
          const delta = chunk.choices?.[0]?.delta?.content;
          if (delta) {
            emittedChars += delta.length;
            controller.enqueue(
              encoder.encode(`data: ${JSON.stringify({ text: delta })}\n\n`),
            );
          }
        }
      },
      cancel() {
        // Client hung up — still bill what we used, then drop upstream.
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

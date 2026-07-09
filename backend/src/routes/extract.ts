import { and, gte, sql } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import { llmUsage } from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

// Document scan-to-import extraction on Cloudflare Workers AI. A vision
// model reads a photographed prescription label / appointment card /
// insurance card and returns structured JSON TEXT the app parses (and the
// caregiver reviews + approves before anything is written). Like the coach
// chat, this runs on Cloudflare Workers AI's OpenAI-compatible endpoint —
// so the PHI image never leaves Cloudflare's network (where R2 already
// stores the scan) and never goes to a separate AI vendor.
export type ExtractBindings = AuthBindings & {
  FORUM_DB: D1Database;
  CF_AI_API_TOKEN: string;
  CLOUDFLARE_ACCOUNT_ID?: string;
  CF_AI_BASE_URL?: string;
  EXTRACT_MODEL?: string;
  // Reuses the same abuse stop as chat (per-user daily token quota).
  CHAT_USER_DAILY_TOKENS?: string;
  // Base64 image size ceiling (chars). A ~2048px JPEG the app pre-shrinks
  // is well under this; the cap blocks payload-stuffing on a public route.
  EXTRACT_MAX_IMAGE_CHARS?: string;
};

export type ExtractVariables = AuthVariables;

const DEFAULTS = {
  // Vision model. VALIDATE the model + prompt on the live account — smaller
  // edge models read messy label photos less reliably than a frontier
  // model; the human-in-the-loop review + uncertainty flags are the
  // mitigation. Llama 3.2 Vision handles the OpenAI image_url message shape.
  model: '@cf/meta/llama-3.2-11b-vision-instruct',
  userDailyTokens: 300_000,
  maxImageChars: 16 * 1024 * 1024, // ~12 MB image → base64 inflates ~33%
} as const;

// Micro-dollar cost proxy (Workers AI bills neurons; tune to plan). Kept
// so extraction spend lands in the same llmUsage ledger as chat.
const INPUT_MICROS_PER_TOKEN = 0.35;
const OUTPUT_MICROS_PER_TOKEN = 0.75;

const num = (v: string | undefined, fallback: number): number => {
  if (v === undefined) return fallback;
  const parsed = Number(v);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const estimateTokens = (text: string): number => Math.ceil(text.length / 4);

function startOfUtcDay(now: number): Date {
  return new Date(Math.floor(now / 86_400_000) * 86_400_000);
}

export function extractRouter() {
  const router = new Hono<{
    Bindings: ExtractBindings;
    Variables: ExtractVariables;
  }>();

  router.post('/', async (c) => {
    const userId = c.get('userId');
    const env = c.env;

    if (!env.CF_AI_API_TOKEN || !env.CLOUDFLARE_ACCOUNT_ID) {
      return c.json({ error: 'server_misconfigured' }, 500);
    }

    // --- Parse + size-cap ------------------------------------------------
    let system = '';
    let user = '';
    let imageBase64: string | undefined;
    try {
      const body = (await c.req.json()) as {
        system?: unknown;
        user?: unknown;
        image_base64?: unknown;
      };
      if (typeof body.system === 'string') system = body.system;
      if (typeof body.user === 'string') user = body.user;
      if (typeof body.image_base64 === 'string') {
        imageBase64 = body.image_base64;
      }
    } catch {
      return c.json({ error: 'bad_request' }, 400);
    }
    if (!imageBase64) {
      return c.json({ error: 'bad_request' }, 400);
    }
    if (
      imageBase64.length >
      num(env.EXTRACT_MAX_IMAGE_CHARS, DEFAULTS.maxImageChars)
    ) {
      return c.json({ error: 'image_too_large' }, 413);
    }

    // --- Per-user daily token quota (shared abuse stop with chat) --------
    const db = drizzle(env.FORUM_DB);
    const dayStart = startOfUtcDay(Date.now());
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
      return c.json({ error: 'daily_limit' }, 429);
    }

    // --- Call the vision model (OpenAI-compatible, non-streaming) --------
    const baseUrl =
      env.CF_AI_BASE_URL ??
      `https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}/ai/v1`;
    const model = env.EXTRACT_MODEL ?? DEFAULTS.model;
    const prompt = [system, user].filter(Boolean).join('\n\n');

    let text = '';
    try {
      const upstream = await fetch(`${baseUrl}/chat/completions`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.CF_AI_API_TOKEN}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model,
          max_tokens: 1024,
          messages: [
            {
              role: 'user',
              content: [
                { type: 'text', text: prompt },
                {
                  type: 'image_url',
                  image_url: { url: `data:image/jpeg;base64,${imageBase64}` },
                },
              ],
            },
          ],
        }),
      });
      if (!upstream.ok) {
        return c.json({ error: 'extract_unavailable' }, 502);
      }
      const data = (await upstream.json()) as {
        choices?: { message?: { content?: string } }[];
      };
      text = data.choices?.[0]?.message?.content ?? '';
    } catch {
      return c.json({ error: 'extract_unavailable' }, 502);
    }

    // --- Meter usage (rough estimate; the image ≈ a fixed prompt cost) ---
    const pt = estimateTokens(prompt) + 512;
    const ct = estimateTokens(text);
    c.executionCtx.waitUntil(
      db
        .insert(llmUsage)
        .values({
          userId,
          model,
          feature: 'extract',
          promptTokens: pt,
          completionTokens: ct,
          costMicros: Math.round(
            pt * INPUT_MICROS_PER_TOKEN + ct * OUTPUT_MICROS_PER_TOKEN,
          ),
        })
        .then(() => undefined),
    );

    // Same contract the shim /extract gives the scanners: the model's raw
    // JSON text under `text`; the app parses + the caregiver approves it.
    return c.json({ text });
  });

  return router;
}

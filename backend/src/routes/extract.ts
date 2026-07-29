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
// Minimal shape of the native Workers AI binding. Non-streaming here (a scan
// is one structured JSON answer, not a typed-out conversation), so `run`
// resolves to a plain result object rather than a ReadableStream.
type WorkersAiBinding = {
  run(model: string, options: Record<string, unknown>): Promise<unknown>;
};

export type ExtractBindings = AuthBindings & {
  FORUM_DB: D1Database;
  // Prefer the native `AI` binding (no runtime token — see `[env.dev.ai]` in
  // wrangler.toml); the REST CF_AI_API_TOKEN path stays as the fallback for
  // an environment configured with a token instead. Until 2026-07-13 this
  // route REQUIRED the token, which is not set on the Cloudflare dev deploy —
  // so every scan-to-import returned 500 server_misconfigured there while
  // chat (already migrated to the binding) worked fine.
  AI?: WorkersAiBinding;
  CF_AI_API_TOKEN?: string;
  CLOUDFLARE_ACCOUNT_ID?: string;
  CF_AI_BASE_URL?: string;
  EXTRACT_MODEL?: string;
  // Text model, used when a caller sends a prompt with NO image (visit-prep
  // questions, insurance-appeal drafts, ambient visit notes, care-plan
  // suggestions). Sending those to the vision model would work at best
  // wastefully; the text model is what they are written for.
  CHAT_MODEL?: string;
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
  //
  // ⚠ ONE-TIME ACCOUNT GATE (hit live 2026-07-13): this model is licence-gated
  // on Workers AI. Until the ACCOUNT accepts Meta's Llama 3.2 Community
  // Licence — by running the model once with the literal prompt `agree` —
  // every call fails with `AiError 5016` ("you must submit the prompt
  // 'agree'"), which this route surfaces as a 502 extract_unavailable. That
  // acceptance is a legal act for the operating company, so it is NOT
  // automated here. See backend/README.md → "Vision model licence".
  model: '@cf/meta/llama-3.2-11b-vision-instruct',
  // Text-only fallback for the object-prompt callers (see CHAT_MODEL above).
  textModel: '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
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

/// The route's contract with the app is `{text: "<the model's raw text>"}` — a
/// STRING the scanners parse themselves. Workers AI doesn't always cooperate:
/// when the model returns well-formed JSON (exactly what our extraction prompts
/// ask for) the binding pre-parses it into an object. Anything that isn't
/// already a string is re-serialised, so the app sees the same shape whether
/// the model answered in prose or in JSON.
export function coerceToText(raw: unknown): string {
  if (typeof raw === 'string') return raw;
  if (raw === null || raw === undefined) return '';
  try {
    return JSON.stringify(raw);
  } catch {
    return String(raw);
  }
}

/** Decode a base64 scan into raw bytes for the AI binding. Returns null on
 * malformed input (a client bug / a hostile payload), which the caller turns
 * into a 400 rather than a 502 — the model never sees it. */
function base64ToBytes(b64: string): Uint8Array | null {
  try {
    const binary = atob(b64);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

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

    if (!env.AI && (!env.CF_AI_API_TOKEN || !env.CLOUDFLARE_ACCOUNT_ID)) {
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
    // An image is OPTIONAL. This route serves two callers: the scanners, which
    // send a photo, and the object-prompt features (visit-prep, insurance
    // appeal, ambient visit note, care-plan suggestions), which send prompt
    // text alone. Rejecting the text-only shape made all of those silently
    // no-op against the deployed Worker — the app's transport catches the 400
    // and returns null, so the feature just quietly produced nothing.
    if (!imageBase64 && !system && !user) {
      return c.json({ error: 'bad_request' }, 400);
    }
    if (
      imageBase64 !== undefined &&
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

    // --- Call the model (non-streaming) ----------------------------------
    // Vision model when there's a photo to read, text model when there isn't.
    const model = imageBase64
      ? (env.EXTRACT_MODEL ?? DEFAULTS.model)
      : (env.CHAT_MODEL ?? DEFAULTS.textModel);
    const prompt = [system, user].filter(Boolean).join('\n\n');

    let text = '';
    try {
      if (env.AI) {
        // Native binding. The Workers AI vision models take the image as a
        // byte array (not a data: URL — that's the OpenAI-compatible REST
        // shape below), alongside a flat prompt.
        let image: number[] | undefined;
        if (imageBase64) {
          const bytes = base64ToBytes(imageBase64);
          if (!bytes) {
            return c.json({ error: 'bad_request' }, 400);
          }
          image = Array.from(bytes);
        }
        const result = (await env.AI.run(model, {
          prompt,
          ...(image ? { image } : {}),
          max_tokens: 1024,
        })) as { response?: unknown; description?: unknown } | undefined;
        // Instruct-tuned vision models answer under `response`; the plain
        // image-to-text ones use `description`. Accept either.
        //
        // ...and NORMALISE IT TO TEXT. When the model actually obeys our
        // extraction prompt and replies with clean JSON, the Workers AI
        // binding hands `response` back ALREADY PARSED — an object, not a
        // string. Passing that through unchanged breaks the app, whose
        // scanners expect `{text: "<json string>"}` and parse it themselves:
        // the BETTER the model behaves, the more surely the scan fails
        // (2026-07-13 — the live suite caught it flapping between a prose
        // string and a JSON object). Re-serialise so the contract holds
        // either way.
        text = coerceToText(result?.response ?? result?.description);
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
            max_tokens: 1024,
            messages: [
              {
                role: 'user',
                content: imageBase64
                  ? [
                      { type: 'text', text: prompt },
                      {
                        type: 'image_url',
                        image_url: {
                          url: `data:image/jpeg;base64,${imageBase64}`,
                        },
                      },
                    ]
                  : prompt,
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
      }
    } catch {
      return c.json({ error: 'extract_unavailable' }, 502);
    }

    // --- Meter usage (rough estimate; the image ≈ a fixed prompt cost) ---
    const pt = estimateTokens(prompt) + (imageBase64 ? 512 : 0);
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

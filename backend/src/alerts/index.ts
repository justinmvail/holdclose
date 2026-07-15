// Real-time operator alerting.
//
// The weekly watchdog (../watchdog) tracks CAPACITY (are we near a
// free-tier cap?). This module covers the other half: an unhandled 5xx or a
// failed cron means the app is BROKEN NOW, and the operator should hear about
// it in minutes, not at the next Monday watchdog run. It reuses the
// watchdog's Resend mailer and is deliberately best-effort — alerting must
// NEVER turn a request error into a crash, so every path here swallows its
// own failures (loudly, to the log) and returns instead of throwing.
//
// De-duplication: a single bad deploy can throw on every request. Without a
// throttle that's thousands of identical emails. `claimAlertSlot` collapses
// repeats of the same signature to one send per ALERT_DEDUP_WINDOW_MS, using
// an atomic D1 upsert so the throttle holds across Worker isolates (an
// in-memory guard would reset per isolate and leak duplicates).

import { ResendMailer, type Mailer } from '../watchdog';

export const ALERT_DEDUP_WINDOW_MS = 15 * 60_000; // one alert / signature / 15 min

export type AlertEnv = {
  FORUM_DB: D1Database;
  RESEND_API_KEY: string;
  RESEND_FROM_EMAIL: string;
  RESEND_TO_EMAIL: string;
  // Optional label so a subject line says which deploy fired ("prod"/"dev").
  ENVIRONMENT?: string;
};

export type Alert = {
  // Stable grouping key — repeats within the window collapse to one send.
  // Keep it free of high-cardinality bits (row ids, timestamps) or nothing
  // ever de-dupes.
  signature: string;
  subject: string;
  text: string;
};

/**
 * Build an [Alert] from an unhandled request error. Pure (takes the request
 * shape, not the Hono context) so it's unit-testable. The signature groups by
 * method + error type + first message line — NOT the path, so the same fault
 * on `/posts/1` and `/posts/2` is one alert, not two.
 */
export function buildErrorAlert(input: {
  method: string;
  path: string;
  err: unknown;
  now?: Date;
  environment?: string;
}): Alert {
  const now = input.now ?? new Date();
  const err = input.err;
  const name = err instanceof Error ? err.name : 'Error';
  const message = err instanceof Error ? err.message : String(err);
  const stack = err instanceof Error ? err.stack : undefined;
  const firstLine = message.split('\n')[0] ?? '';

  const signature = `${input.method} ${name}: ${firstLine}`.slice(0, 160);
  const envLabel = input.environment ? `[${input.environment}] ` : '';
  const subject = `${envLabel}[Holdclose] Worker 5xx: ${input.method} ${input.path}`;
  const text = [
    `Holdclose Worker error — ${now.toISOString()}`,
    input.environment ? `Environment: ${input.environment}` : null,
    '',
    `Request: ${input.method} ${input.path}`,
    `Error:   ${name}: ${message}`,
    '',
    stack ? `Stack:\n${stack}` : '(no stack captured)',
    '',
    'Automated alert from the Worker error boundary (app.onError).',
    `Repeats of this error are collapsed to one alert per ${
      ALERT_DEDUP_WINDOW_MS / 60_000
    } minutes.`,
  ]
    .filter((l): l is string => l !== null)
    .join('\n');

  return { signature, subject, text };
}

/**
 * Send an operator alert by email, best-effort and rate-limited.
 *
 * Returns `true` only if an email was actually sent. Returns `false` (never
 * throws) when: alerting isn't configured (no RESEND_* — e.g. tests, or a
 * deploy before the secret is set), the signature is still within its dedup
 * window, or the send itself failed. Callers fire-and-forget via
 * `ctx.waitUntil`.
 */
export async function alertOnError(
  env: AlertEnv,
  alert: Alert,
  opts: {
    now?: () => number;
    mailerFactory?: (env: AlertEnv) => Mailer;
  } = {},
): Promise<boolean> {
  try {
    if (!env.RESEND_API_KEY || !env.RESEND_FROM_EMAIL || !env.RESEND_TO_EMAIL) {
      return false; // alerting not configured — stay silent, never crash
    }
    const nowMs = (opts.now ?? Date.now)();
    const claimed = await claimAlertSlot(env.FORUM_DB, alert.signature, nowMs);
    if (!claimed) return false; // still within the dedup window for this signature

    const mailer = (opts.mailerFactory ?? defaultMailer)(env);
    await mailer.send({
      from: env.RESEND_FROM_EMAIL,
      to: env.RESEND_TO_EMAIL,
      subject: alert.subject,
      text: alert.text,
    });
    return true;
  } catch (e) {
    // The alert failing must not propagate — log and move on.
    console.error('alertOnError failed', e);
    return false;
  }
}

function defaultMailer(env: AlertEnv): Mailer {
  return new ResendMailer({ RESEND_API_KEY: env.RESEND_API_KEY });
}

/**
 * Atomically decide whether `signature` may alert right now. Inserts (or
 * refreshes, once the window has elapsed) the last-sent timestamp in a single
 * statement; `meta.changes > 0` means this caller won the slot and should
 * send. The ON CONFLICT ... WHERE means a repeat inside the window is a no-op
 * (0 changes → false). The table is self-bootstrapping (CREATE IF NOT EXISTS)
 * so alerting needs no separate migration to come online on deploy.
 */
async function claimAlertSlot(
  db: D1Database,
  signature: string,
  nowMs: number,
): Promise<boolean> {
  await db
    .prepare(
      `CREATE TABLE IF NOT EXISTS alert_dedup (
         signature TEXT PRIMARY KEY,
         last_sent_at INTEGER NOT NULL
       )`,
    )
    .run();

  const cutoff = nowMs - ALERT_DEDUP_WINDOW_MS;
  const res = await db
    .prepare(
      `INSERT INTO alert_dedup (signature, last_sent_at) VALUES (?1, ?2)
       ON CONFLICT(signature) DO UPDATE SET last_sent_at = ?2
       WHERE alert_dedup.last_sent_at <= ?3`,
    )
    .bind(signature, nowMs, cutoff)
    .run();

  return (res.meta?.changes ?? 0) > 0;
}

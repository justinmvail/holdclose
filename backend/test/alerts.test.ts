import { env } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';

import {
  ALERT_DEDUP_WINDOW_MS,
  alertOnError,
  buildErrorAlert,
  type Alert,
  type AlertEnv,
} from '../src/alerts';
import type { Mailer } from '../src/watchdog';

type SentMessage = Parameters<Mailer['send']>[0];

function recordingMailer(): { mailer: Mailer; sent: SentMessage[] } {
  const sent: SentMessage[] = [];
  return {
    sent,
    mailer: {
      async send(message) {
        sent.push(message);
      },
    },
  };
}

function throwingMailer(): Mailer {
  return {
    async send() {
      throw new Error('Resend send failed: 422 domain not verified');
    },
  };
}

// A configured env pointing at the miniflare D1 the harness provides.
function alertEnv(overrides: Partial<AlertEnv> = {}): AlertEnv {
  return {
    FORUM_DB: env.FORUM_DB,
    RESEND_API_KEY: 're_test_key',
    RESEND_FROM_EMAIL: 'onboarding@resend.dev',
    RESEND_TO_EMAIL: 'ops@example.com',
    ENVIRONMENT: 'test',
    ...overrides,
  };
}

const alert: Alert = {
  signature: 'GET Error: boom',
  subject: '[Holdclose] Worker 5xx: GET /api/v1/posts',
  text: 'boom',
};

beforeEach(async () => {
  // The dedup table self-bootstraps; drop it so each test starts clean.
  await env.FORUM_DB.prepare('DROP TABLE IF EXISTS alert_dedup').run();
});

describe('buildErrorAlert', () => {
  it('groups by method + error type + first message line, not by path', () => {
    const a = buildErrorAlert({
      method: 'GET',
      path: '/api/v1/posts/1',
      err: new Error('D1_ERROR: no such column'),
    });
    const b = buildErrorAlert({
      method: 'GET',
      path: '/api/v1/posts/2',
      err: new Error('D1_ERROR: no such column'),
    });
    // Same fault on two ids collapses to one signature.
    expect(a.signature).toBe(b.signature);
    expect(a.signature).toContain('GET');
    expect(a.signature).toContain('D1_ERROR: no such column');
  });

  it('includes the environment label in the subject when provided', () => {
    const a = buildErrorAlert({
      method: 'POST',
      path: '/api/v1/chat',
      err: new Error('kaboom'),
      environment: 'prod',
    });
    expect(a.subject).toContain('[prod]');
    expect(a.subject).toContain('POST /api/v1/chat');
    expect(a.text).toContain('kaboom');
  });

  it('handles a non-Error throw without crashing', () => {
    const a = buildErrorAlert({ method: 'GET', path: '/x', err: 'a string' });
    expect(a.text).toContain('a string');
  });
});

describe('alertOnError', () => {
  it('sends an email the first time a signature is seen', async () => {
    const { mailer, sent } = recordingMailer();
    const ok = await alertOnError(alertEnv(), alert, {
      now: () => 1_000_000,
      mailerFactory: () => mailer,
    });
    expect(ok).toBe(true);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({
      from: 'onboarding@resend.dev',
      to: 'ops@example.com',
      subject: alert.subject,
    });
  });

  it('suppresses a repeat of the same signature within the dedup window', async () => {
    const { mailer, sent } = recordingMailer();
    const factory = () => mailer;

    const first = await alertOnError(alertEnv(), alert, {
      now: () => 1_000_000,
      mailerFactory: factory,
    });
    // 5 minutes later — still inside the 15-minute window.
    const second = await alertOnError(alertEnv(), alert, {
      now: () => 1_000_000 + 5 * 60_000,
      mailerFactory: factory,
    });

    expect(first).toBe(true);
    expect(second).toBe(false);
    expect(sent).toHaveLength(1); // only the first went out
  });

  it('sends again once the dedup window has elapsed', async () => {
    const { mailer, sent } = recordingMailer();
    const factory = () => mailer;

    await alertOnError(alertEnv(), alert, {
      now: () => 1_000_000,
      mailerFactory: factory,
    });
    const later = await alertOnError(alertEnv(), alert, {
      now: () => 1_000_000 + ALERT_DEDUP_WINDOW_MS + 1,
      mailerFactory: factory,
    });

    expect(later).toBe(true);
    expect(sent).toHaveLength(2);
  });

  it('treats different signatures independently', async () => {
    const { mailer, sent } = recordingMailer();
    const factory = () => mailer;
    const now = () => 1_000_000;

    await alertOnError(alertEnv(), alert, { now, mailerFactory: factory });
    await alertOnError(
      alertEnv(),
      { ...alert, signature: 'POST Error: different' },
      { now, mailerFactory: factory },
    );

    expect(sent).toHaveLength(2);
  });

  it('stays silent (no throw, no send) when alerting is unconfigured', async () => {
    const { mailer, sent } = recordingMailer();
    const ok = await alertOnError(
      alertEnv({ RESEND_API_KEY: '' }),
      alert,
      { now: () => 1_000_000, mailerFactory: () => mailer },
    );
    expect(ok).toBe(false);
    expect(sent).toHaveLength(0);
  });

  it('never throws when the mailer fails — returns false', async () => {
    const ok = await alertOnError(alertEnv(), alert, {
      now: () => 1_000_000,
      mailerFactory: () => throwingMailer(),
    });
    expect(ok).toBe(false);
  });
});

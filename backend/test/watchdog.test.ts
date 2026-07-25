import { env } from 'cloudflare:test';
import { drizzle } from 'drizzle-orm/d1';
import { beforeEach, describe, expect, it } from 'vitest';

import { comments, posts, profiles } from '../src/db/schema';
import {
  buildEmail,
  CloudflareAnalyticsClient,
  computeFlags,
  gatherDbMetrics,
  highestSeverity,
  ResendMailer,
  runWatchdog,
  THRESHOLDS,
  type AnalyticsSnapshot,
  type AnalyticsSource,
  type Mailer,
  type Metrics,
} from '../src/watchdog';

async function clearTables() {
  await env.FORUM_DB.batch([
    env.FORUM_DB.prepare('DELETE FROM reports'),
    env.FORUM_DB.prepare('DELETE FROM votes'),
    env.FORUM_DB.prepare('DELETE FROM comments'),
    env.FORUM_DB.prepare('DELETE FROM posts'),
    env.FORUM_DB.prepare('DELETE FROM profiles'),
  ]);
}

beforeEach(async () => {
  await clearTables();
});

const cleanSnapshot: AnalyticsSnapshot = {
  d1SizeBytes: 0,
  d1WritesPerDay: 0,
  d1P95QueryMs: 0,
  workerRequestCount: 0,
  workerP95LatencyMs: 0,
  r2StorageBytes: 0,
  r2GetCount: 0,
  r2PutCount: 0,
};

const cleanMetrics: Metrics = {
  totalRows: 0,
  postsLast30d: 0,
  commentsLast30d: 0,
  monthlyActiveAuthors: 0,
  ...cleanSnapshot,
};

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

const NOW = new Date('2026-05-30T13:00:00.000Z');

describe('computeFlags', () => {
  it('returns no flags when every metric is below the yellow line', () => {
    expect(computeFlags(cleanMetrics)).toEqual([]);
  });

  it('flags yellow when a value exactly hits the yellow threshold', () => {
    const flags = computeFlags({
      ...cleanMetrics,
      d1SizeBytes: THRESHOLDS.d1SizeBytes.yellow,
    });
    expect(flags).toHaveLength(1);
    expect(flags[0]).toMatchObject({
      metric: 'd1SizeBytes',
      severity: 'yellow',
      threshold: THRESHOLDS.d1SizeBytes.yellow,
    });
  });

  it('stays yellow up until the red threshold is crossed', () => {
    const flags = computeFlags({
      ...cleanMetrics,
      r2StorageBytes: THRESHOLDS.r2StorageBytes.red - 1,
    });
    expect(flags[0]?.severity).toBe('yellow');
  });

  it('escalates a single metric to red once it crosses the red line', () => {
    const flags = computeFlags({
      ...cleanMetrics,
      d1WritesPerDay: THRESHOLDS.d1WritesPerDay.red,
    });
    expect(flags[0]).toMatchObject({
      metric: 'd1WritesPerDay',
      severity: 'red',
      threshold: THRESHOLDS.d1WritesPerDay.red,
    });
  });

  it('flags every metric independently', () => {
    const metrics: Metrics = {
      ...cleanMetrics,
      d1SizeBytes: THRESHOLDS.d1SizeBytes.red,
      d1WritesPerDay: THRESHOLDS.d1WritesPerDay.yellow,
      d1P95QueryMs: THRESHOLDS.d1P95QueryMs.yellow,
      monthlyActiveAuthors: THRESHOLDS.monthlyActiveAuthors.red,
      r2StorageBytes: THRESHOLDS.r2StorageBytes.yellow,
    };
    const severities = computeFlags(metrics).map((f) => `${f.metric}:${f.severity}`);
    expect(severities).toEqual([
      'd1SizeBytes:red',
      'd1WritesPerDay:yellow',
      'd1P95QueryMs:yellow',
      'monthlyActiveAuthors:red',
      'r2StorageBytes:yellow',
    ]);
  });
});

describe('highestSeverity', () => {
  it('returns green for an empty flag list', () => {
    expect(highestSeverity([])).toBe('green');
  });

  it('returns yellow when only yellow flags are present', () => {
    const flags = computeFlags({
      ...cleanMetrics,
      d1SizeBytes: THRESHOLDS.d1SizeBytes.yellow,
    });
    expect(highestSeverity(flags)).toBe('yellow');
  });

  it('prefers red over yellow when both are present', () => {
    const flags = computeFlags({
      ...cleanMetrics,
      d1SizeBytes: THRESHOLDS.d1SizeBytes.yellow,
      d1P95QueryMs: THRESHOLDS.d1P95QueryMs.red,
    });
    expect(highestSeverity(flags)).toBe('red');
  });
});

describe('buildEmail', () => {
  it('marks the subject YELLOW when no red flags fired', () => {
    const metrics = {
      ...cleanMetrics,
      d1SizeBytes: THRESHOLDS.d1SizeBytes.yellow,
    };
    const flags = computeFlags(metrics);
    const { subject, text } = buildEmail(flags, metrics, NOW);
    expect(subject).toContain('YELLOW');
    expect(subject).toContain('1 metric');
    expect(text).toContain('Highest severity: YELLOW');
    expect(text).toContain('D1 size');
    expect(text).toContain('4.00 GB');
    expect(text).toContain(NOW.toISOString());
  });

  it('marks the subject RED when any red flag fires', () => {
    const metrics = {
      ...cleanMetrics,
      d1SizeBytes: THRESHOLDS.d1SizeBytes.red,
      r2StorageBytes: THRESHOLDS.r2StorageBytes.yellow,
    };
    const flags = computeFlags(metrics);
    const { subject, text } = buildEmail(flags, metrics, NOW);
    expect(subject).toContain('RED');
    expect(subject).toContain('2 metrics');
    expect(text).toContain('Highest severity: RED');
    expect(text).toContain('R2 storage');
  });

  it('includes the full snapshot in the email body for context', () => {
    const metrics: Metrics = {
      ...cleanMetrics,
      totalRows: 1234,
      postsLast30d: 12,
      commentsLast30d: 30,
      monthlyActiveAuthors: 7,
      workerRequestCount: 999,
      workerP95LatencyMs: 11,
      r2GetCount: 88,
      r2PutCount: 4,
      d1SizeBytes: THRESHOLDS.d1SizeBytes.yellow,
    };
    const flags = computeFlags(metrics);
    const { text } = buildEmail(flags, metrics, NOW);
    expect(text).toContain('Total rows in D1: 1,234');
    expect(text).toContain('Posts last 30d: 12');
    expect(text).toContain('Comments last 30d: 30');
    expect(text).toContain('Worker requests/week: 999');
    expect(text).toContain('R2 GET/week: 88');
    expect(text).toContain('R2 PUT/week: 4');
  });
});

describe('gatherDbMetrics', () => {
  it('counts posts/comments in the trailing 30 days plus total rows', async () => {
    const orm = drizzle(env.FORUM_DB);
    const oneWeekAgo = new Date(NOW.getTime() - 7 * 86_400_000);
    const sixtyDaysAgo = new Date(NOW.getTime() - 60 * 86_400_000);

    const [authorA] = await orm
      .insert(profiles)
      .values({ displayName: 'a', holdcloseUserId: 'cb-a' })
      .returning();
    const [authorB] = await orm
      .insert(profiles)
      .values({ displayName: 'b', holdcloseUserId: 'cb-b' })
      .returning();

    const [recentPost] = await orm
      .insert(posts)
      .values({
        authorId: authorA.id,
        title: 'recent',
        body: 'recent',
        createdAt: oneWeekAgo,
        updatedAt: oneWeekAgo,
      })
      .returning();
    await orm.insert(posts).values({
      authorId: authorB.id,
      title: 'old',
      body: 'old',
      createdAt: sixtyDaysAgo,
      updatedAt: sixtyDaysAgo,
    });
    await orm.insert(posts).values({
      authorId: authorA.id,
      title: 'recent-2',
      body: 'recent-2',
      createdAt: oneWeekAgo,
      updatedAt: oneWeekAgo,
    });
    await orm.insert(comments).values({
      postId: recentPost.id,
      authorId: authorB.id,
      body: 'in window',
      createdAt: oneWeekAgo,
    });

    const metrics = await gatherDbMetrics(env.FORUM_DB, NOW);
    expect(metrics.postsLast30d).toBe(2);
    expect(metrics.commentsLast30d).toBe(1);
    // authorA posted; authorB commented — both are monthly-active.
    expect(metrics.monthlyActiveAuthors).toBe(2);
    // 2 profiles + 3 posts + 1 comment
    expect(metrics.totalRows).toBe(6);
  });

  it('reports an empty database as all-zero', async () => {
    const metrics = await gatherDbMetrics(env.FORUM_DB, NOW);
    expect(metrics).toEqual({
      totalRows: 0,
      postsLast30d: 0,
      commentsLast30d: 0,
      monthlyActiveAuthors: 0,
    });
  });

  it('deduplicates an author who both posted and commented', async () => {
    const orm = drizzle(env.FORUM_DB);
    const recent = new Date(NOW.getTime() - 86_400_000);
    const [author] = await orm
      .insert(profiles)
      .values({ displayName: 'solo', holdcloseUserId: 'cb-solo' })
      .returning();
    const [post] = await orm
      .insert(posts)
      .values({
        authorId: author.id,
        title: 't',
        body: 'b',
        createdAt: recent,
        updatedAt: recent,
      })
      .returning();
    await orm.insert(comments).values({
      postId: post.id,
      authorId: author.id,
      body: 'self-reply',
      createdAt: recent,
    });

    const metrics = await gatherDbMetrics(env.FORUM_DB, NOW);
    expect(metrics.monthlyActiveAuthors).toBe(1);
  });
});

describe('runWatchdog', () => {
  const greenAnalytics: AnalyticsSource = {
    async fetchSnapshot() {
      return cleanSnapshot;
    },
  };

  it('returns green and sends no email when every metric is healthy', async () => {
    const { mailer, sent } = recordingMailer();
    const result = await runWatchdog({
      db: env.FORUM_DB,
      analytics: greenAnalytics,
      mailer,
      operatorEmail: 'ops@holdclose.local',
      fromEmail: 'watchdog@holdclose.local',
      now: () => NOW,
    });
    expect(result.severity).toBe('green');
    expect(result.emailSent).toBe(false);
    expect(sent).toEqual([]);
  });

  it('sends a YELLOW email when any metric crosses the yellow line', async () => {
    const { mailer, sent } = recordingMailer();
    const snapshot: AnalyticsSnapshot = {
      ...cleanSnapshot,
      d1SizeBytes: THRESHOLDS.d1SizeBytes.yellow,
    };
    const result = await runWatchdog({
      db: env.FORUM_DB,
      analytics: { async fetchSnapshot() { return snapshot; } },
      mailer,
      operatorEmail: 'ops@holdclose.local',
      fromEmail: 'watchdog@holdclose.local',
      now: () => NOW,
    });
    expect(result.severity).toBe('yellow');
    expect(result.emailSent).toBe(true);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({
      to: 'ops@holdclose.local',
      from: 'watchdog@holdclose.local',
    });
    expect(sent[0].subject).toContain('YELLOW');
    expect(sent[0].text).toContain('D1 size');
  });

  it('sends a RED email when at least one metric crosses the red line', async () => {
    const { mailer, sent } = recordingMailer();
    const snapshot: AnalyticsSnapshot = {
      ...cleanSnapshot,
      d1SizeBytes: THRESHOLDS.d1SizeBytes.red + 1,
      r2StorageBytes: THRESHOLDS.r2StorageBytes.yellow,
    };
    const result = await runWatchdog({
      db: env.FORUM_DB,
      analytics: { async fetchSnapshot() { return snapshot; } },
      mailer,
      operatorEmail: 'ops@holdclose.local',
      fromEmail: 'watchdog@holdclose.local',
      now: () => NOW,
    });
    expect(result.severity).toBe('red');
    expect(sent[0].subject).toContain('RED');
    expect(sent[0].subject).toContain('2 metrics');
  });

  it('propagates analytics failures instead of mailing partial data', async () => {
    const { mailer, sent } = recordingMailer();
    const failing: AnalyticsSource = {
      async fetchSnapshot() {
        throw new Error('analytics fetch failed');
      },
    };
    await expect(
      runWatchdog({
        db: env.FORUM_DB,
        analytics: failing,
        mailer,
        operatorEmail: 'ops@holdclose.local',
        fromEmail: 'watchdog@holdclose.local',
        now: () => NOW,
      }),
    ).rejects.toThrow('analytics fetch failed');
    expect(sent).toEqual([]);
  });
});

describe('CloudflareAnalyticsClient', () => {
  it('POSTs a bearer-authed GraphQL query and parses the response', async () => {
    const calls: { url: string; init?: RequestInit }[] = [];
    const fakeFetch: typeof fetch = async (input, init) => {
      const url =
        typeof input === 'string'
          ? input
          : input instanceof URL
            ? input.toString()
            : (input as Request).url;
      calls.push({ url, init });
      return new Response(
        JSON.stringify({
          data: {
            viewer: {
              accounts: [
                {
                  workersInvocationsAdaptive: [
                    { sum: { requests: 12_345 }, quantiles: { wallTimeP95: 42 } },
                  ],
                  d1AnalyticsAdaptiveGroups: [
                    {
                      sum: { readQueries: 70_000, writeQueries: 7_000 },
                      quantiles: { queryDurationP95: 55 },
                      max: { databaseSizeBytes: 5_368_709_120 },
                    },
                  ],
                  r2StorageAdaptiveGroups: [
                    { max: { payloadSize: 110 * 1024 * 1024 * 1024 } },
                  ],
                  r2OperationsAdaptiveGroups: [
                    { sum: { requests: 9_999 }, dimensions: { actionType: 'GetObject' } },
                    { sum: { requests: 88 }, dimensions: { actionType: 'PutObject' } },
                  ],
                },
              ],
            },
          },
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    };

    const client = new CloudflareAnalyticsClient(
      {
        CLOUDFLARE_ACCOUNT_ID: 'acct-1',
        CLOUDFLARE_API_TOKEN: 'token-1',
        CLOUDFLARE_D1_DATABASE_ID: 'db-1',
        CLOUDFLARE_R2_BUCKET_NAME: 'bucket-1',
      },
      fakeFetch,
    );

    const snapshot = await client.fetchSnapshot(NOW);

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe('https://api.cloudflare.com/client/v4/graphql');
    expect(calls[0].init?.method).toBe('POST');
    const headers = calls[0].init?.headers as Record<string, string> | undefined;
    expect(headers?.Authorization).toBe('Bearer token-1');
    expect(headers?.['Content-Type']).toBe('application/json');

    const sentBody = JSON.parse((calls[0].init?.body as string) ?? '{}');
    expect(sentBody.variables.accountTag).toBe('acct-1');
    expect(sentBody.variables.dbId).toBe('db-1');
    expect(sentBody.variables.bucket).toBe('bucket-1');
    expect(sentBody.variables.start).toBe('2026-05-23');
    expect(sentBody.variables.end).toBe('2026-05-30');

    expect(snapshot).toEqual({
      d1SizeBytes: 5_368_709_120,
      // 7_000 writes / 7-day window = 1000 writes/day
      d1WritesPerDay: 1_000,
      d1P95QueryMs: 55,
      workerRequestCount: 12_345,
      workerP95LatencyMs: 42,
      r2StorageBytes: 110 * 1024 * 1024 * 1024,
      r2GetCount: 9_999,
      r2PutCount: 88,
    });
  });

  it('throws when the analytics endpoint returns a non-2xx status', async () => {
    const client = new CloudflareAnalyticsClient(
      {
        CLOUDFLARE_ACCOUNT_ID: 'acct',
        CLOUDFLARE_API_TOKEN: 'token',
        CLOUDFLARE_D1_DATABASE_ID: 'db',
        CLOUDFLARE_R2_BUCKET_NAME: 'bucket',
      },
      async () =>
        new Response('forbidden', { status: 403, statusText: 'Forbidden' }),
    );
    await expect(client.fetchSnapshot(NOW)).rejects.toThrow(/403/);
  });

  it('throws when the analytics payload contains GraphQL errors', async () => {
    const client = new CloudflareAnalyticsClient(
      {
        CLOUDFLARE_ACCOUNT_ID: 'acct',
        CLOUDFLARE_API_TOKEN: 'token',
        CLOUDFLARE_D1_DATABASE_ID: 'db',
        CLOUDFLARE_R2_BUCKET_NAME: 'bucket',
      },
      async () =>
        new Response(
          JSON.stringify({ errors: [{ message: 'no permission' }] }),
          { status: 200 },
        ),
    );
    await expect(client.fetchSnapshot(NOW)).rejects.toThrow(/no permission/);
  });

  it('throws when the response contains no account data', async () => {
    const client = new CloudflareAnalyticsClient(
      {
        CLOUDFLARE_ACCOUNT_ID: 'acct',
        CLOUDFLARE_API_TOKEN: 'token',
        CLOUDFLARE_D1_DATABASE_ID: 'db',
        CLOUDFLARE_R2_BUCKET_NAME: 'bucket',
      },
      async () =>
        new Response(JSON.stringify({ data: { viewer: { accounts: [] } } }), {
          status: 200,
        }),
    );
    await expect(client.fetchSnapshot(NOW)).rejects.toThrow(/no account data/);
  });
});

describe('ResendMailer', () => {
  it('POSTs to the Resend API with the bearer token and the message body', async () => {
    const calls: { url: string; init?: RequestInit }[] = [];
    const fakeFetch: typeof fetch = async (input, init) => {
      const url =
        typeof input === 'string'
          ? input
          : input instanceof URL
            ? input.toString()
            : (input as Request).url;
      calls.push({ url, init });
      return new Response(JSON.stringify({ id: 'resend-1' }), { status: 200 });
    };
    const mailer = new ResendMailer({ RESEND_API_KEY: 'rk_test' }, fakeFetch);

    await mailer.send({
      from: 'watchdog@holdclose.local',
      to: 'ops@holdclose.local',
      subject: '[Holdclose] YELLOW',
      text: 'body',
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe('https://api.resend.com/emails');
    const headers = calls[0].init?.headers as Record<string, string> | undefined;
    expect(headers?.Authorization).toBe('Bearer rk_test');
    const body = JSON.parse((calls[0].init?.body as string) ?? '{}');
    expect(body).toEqual({
      from: 'watchdog@holdclose.local',
      to: 'ops@holdclose.local',
      subject: '[Holdclose] YELLOW',
      text: 'body',
    });
  });

  it('throws when Resend returns a non-2xx response', async () => {
    const mailer = new ResendMailer(
      { RESEND_API_KEY: 'rk_test' },
      async () => new Response('rate limited', { status: 429 }),
    );
    await expect(
      mailer.send({ from: 'a', to: 'b', subject: 's', text: 't' }),
    ).rejects.toThrow(/429/);
  });
});

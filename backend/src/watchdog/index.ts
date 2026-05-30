// Phase 13.13: weekly metrics watchdog.
//
// Cloudflare scheduled Worker that runs Mondays at 13:00 UTC, samples
// the platform's free-tier-adjacent metrics (D1 binding + Cloudflare
// Analytics GraphQL + R2 operations), and emails the operator via
// Resend if any metric is at >= 50% (yellow) or >= 75% (red) of its
// documented soft cap. If every metric is green: silent.
//
// Threshold definitions are duplicated in backend/README.md ("Watchdog
// thresholds") — keep both in sync when tuning.

import { sql } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';

import { comments, posts, profiles } from '../db/schema';

const GB = 1024 * 1024 * 1024;
const MS_PER_DAY = 86_400_000;
const ANALYTICS_WINDOW_DAYS = 7;

export const THRESHOLDS = {
  d1SizeBytes:          { yellow: 4 * GB,    red: 7 * GB,    label: 'D1 size',                unit: 'bytes' as const },
  d1WritesPerDay:       { yellow: 50_000,    red: 500_000,   label: 'D1 writes/day',          unit: 'count' as const },
  d1P95QueryMs:         { yellow: 50,        red: 200,       label: 'D1 p95 query latency',   unit: 'ms'    as const },
  monthlyActiveAuthors: { yellow: 50_000,    red: 500_000,   label: 'Monthly active authors', unit: 'count' as const },
  r2StorageBytes:       { yellow: 100 * GB,  red: 500 * GB,  label: 'R2 storage',             unit: 'bytes' as const },
} as const;

export type MetricKey = keyof typeof THRESHOLDS;
export type Severity = 'green' | 'yellow' | 'red';

export type Flag = {
  metric: MetricKey;
  severity: 'yellow' | 'red';
  value: number;
  threshold: number;
  label: string;
  unit: 'bytes' | 'count' | 'ms';
};

export type DbMetrics = {
  totalRows: number;
  postsLast30d: number;
  commentsLast30d: number;
  monthlyActiveAuthors: number;
};

export type AnalyticsSnapshot = {
  d1SizeBytes: number;
  d1WritesPerDay: number;
  d1P95QueryMs: number;
  workerRequestCount: number;
  workerP95LatencyMs: number;
  r2StorageBytes: number;
  r2GetCount: number;
  r2PutCount: number;
};

export type Metrics = DbMetrics & AnalyticsSnapshot;

// ---------- Pure threshold / formatting helpers ----------

export function computeFlags(metrics: Metrics): Flag[] {
  const checks: ReadonlyArray<{ key: MetricKey; value: number }> = [
    { key: 'd1SizeBytes',          value: metrics.d1SizeBytes },
    { key: 'd1WritesPerDay',       value: metrics.d1WritesPerDay },
    { key: 'd1P95QueryMs',         value: metrics.d1P95QueryMs },
    { key: 'monthlyActiveAuthors', value: metrics.monthlyActiveAuthors },
    { key: 'r2StorageBytes',       value: metrics.r2StorageBytes },
  ];

  const flags: Flag[] = [];
  for (const { key, value } of checks) {
    const t = THRESHOLDS[key];
    if (value >= t.red) {
      flags.push({ metric: key, severity: 'red', value, threshold: t.red, label: t.label, unit: t.unit });
    } else if (value >= t.yellow) {
      flags.push({ metric: key, severity: 'yellow', value, threshold: t.yellow, label: t.label, unit: t.unit });
    }
  }
  return flags;
}

export function highestSeverity(flags: ReadonlyArray<Flag>): Severity {
  if (flags.some((f) => f.severity === 'red')) return 'red';
  if (flags.length > 0) return 'yellow';
  return 'green';
}

function formatValue(value: number, unit: Flag['unit']): string {
  if (unit === 'bytes') {
    if (value >= GB) return `${(value / GB).toFixed(2)} GB`;
    if (value >= 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(2)} MB`;
    return `${value} B`;
  }
  if (unit === 'ms') return `${value} ms`;
  return value.toLocaleString('en-US');
}

export function buildEmail(
  flags: ReadonlyArray<Flag>,
  metrics: Metrics,
  generatedAt: Date,
): { subject: string; text: string } {
  const severity = highestSeverity(flags);
  const subject = severity === 'red'
    ? `[Careblazers] RED: ${flags.length} metric${flags.length === 1 ? '' : 's'} at 75%+ of cap`
    : `[Careblazers] YELLOW: ${flags.length} metric${flags.length === 1 ? '' : 's'} at 50%+ of cap`;

  const lines: string[] = [];
  lines.push(`Careblazers weekly watchdog — ${generatedAt.toISOString()}`);
  lines.push('');
  lines.push(`Highest severity: ${severity.toUpperCase()}`);
  lines.push('');
  lines.push('Flags:');
  for (const flag of flags) {
    lines.push(
      `  - ${flag.severity.toUpperCase()}  ${flag.label}: ${formatValue(flag.value, flag.unit)} ` +
        `(threshold ${formatValue(flag.threshold, flag.unit)})`,
    );
  }
  lines.push('');
  lines.push('Snapshot:');
  lines.push(`  - Total rows in D1: ${metrics.totalRows.toLocaleString('en-US')}`);
  lines.push(`  - Posts last 30d: ${metrics.postsLast30d.toLocaleString('en-US')}`);
  lines.push(`  - Comments last 30d: ${metrics.commentsLast30d.toLocaleString('en-US')}`);
  lines.push(`  - Monthly active authors: ${metrics.monthlyActiveAuthors.toLocaleString('en-US')}`);
  lines.push(`  - D1 size: ${formatValue(metrics.d1SizeBytes, 'bytes')}`);
  lines.push(`  - D1 writes/day: ${metrics.d1WritesPerDay.toLocaleString('en-US')}`);
  lines.push(`  - D1 p95 query: ${metrics.d1P95QueryMs} ms`);
  lines.push(`  - Worker requests/week: ${metrics.workerRequestCount.toLocaleString('en-US')}`);
  lines.push(`  - Worker p95 latency: ${metrics.workerP95LatencyMs} ms`);
  lines.push(`  - R2 storage: ${formatValue(metrics.r2StorageBytes, 'bytes')}`);
  lines.push(`  - R2 GET/week: ${metrics.r2GetCount.toLocaleString('en-US')}`);
  lines.push(`  - R2 PUT/week: ${metrics.r2PutCount.toLocaleString('en-US')}`);
  lines.push('');
  lines.push('Threshold definitions: see backend/README.md → "Watchdog thresholds".');
  return { subject, text: lines.join('\n') };
}

// ---------- D1-binding metric gathering ----------

export async function gatherDbMetrics(
  db: D1Database,
  now: Date,
): Promise<DbMetrics> {
  const cutoffMs = now.getTime() - 30 * MS_PER_DAY;
  const orm = drizzle(db);

  const [postsRecent] = await orm
    .select({ c: sql<number>`count(*)` })
    .from(posts)
    .where(sql`${posts.createdAt} >= ${cutoffMs}`);
  const [commentsRecent] = await orm
    .select({ c: sql<number>`count(*)` })
    .from(comments)
    .where(sql`${comments.createdAt} >= ${cutoffMs}`);

  const [postsTotal] = await orm.select({ c: sql<number>`count(*)` }).from(posts);
  const [commentsTotal] = await orm.select({ c: sql<number>`count(*)` }).from(comments);
  const [profilesTotal] = await orm.select({ c: sql<number>`count(*)` }).from(profiles);

  // Monthly active authors = distinct profile ids that posted OR
  // commented in the trailing 30 days. drizzle-on-D1's query builder
  // doesn't expose a UNION helper, so we drop to raw SQL here.
  const activeAuthors = await db
    .prepare(
      `SELECT COUNT(*) AS c FROM (
         SELECT author_id FROM posts WHERE created_at >= ?
         UNION
         SELECT author_id FROM comments WHERE created_at >= ?
       )`,
    )
    .bind(cutoffMs, cutoffMs)
    .first<{ c: number }>();

  return {
    totalRows: (postsTotal?.c ?? 0) + (commentsTotal?.c ?? 0) + (profilesTotal?.c ?? 0),
    postsLast30d: postsRecent?.c ?? 0,
    commentsLast30d: commentsRecent?.c ?? 0,
    monthlyActiveAuthors: activeAuthors?.c ?? 0,
  };
}

// ---------- Pluggable analytics + mailer seams ----------

export interface AnalyticsSource {
  fetchSnapshot(now: Date): Promise<AnalyticsSnapshot>;
}

export interface Mailer {
  send(message: {
    from: string;
    to: string;
    subject: string;
    text: string;
  }): Promise<void>;
}

// ---------- Cloudflare GraphQL analytics client ----------
//
// Cloudflare Workers Analytics + D1 Analytics + R2 Analytics all live
// behind https://api.cloudflare.com/client/v4/graphql. A single batched
// query covers Worker invocations, D1 query/write/latency, R2 storage
// + GET/PUT counts. The API token must include "Account Analytics:
// Read"; in production it lives as a Worker secret (see
// backend/README.md → "Watchdog setup").

const CLOUDFLARE_GRAPHQL_URL = 'https://api.cloudflare.com/client/v4/graphql';

const ANALYTICS_QUERY = `
  query Watchdog(
    $accountTag: String!,
    $start: Date!,
    $end: Date!,
    $dbId: String!,
    $bucket: String!
  ) {
    viewer {
      accounts(filter: { accountTag: $accountTag }) {
        workersInvocationsAdaptive(
          limit: 1
          filter: { date_geq: $start, date_leq: $end }
        ) {
          sum { requests }
          quantiles { wallTimeP95 }
        }
        d1AnalyticsAdaptiveGroups(
          limit: 1
          filter: { date_geq: $start, date_leq: $end, databaseId: $dbId }
        ) {
          sum { readQueries writeQueries }
          quantiles { queryDurationP95 }
          max { databaseSizeBytes }
        }
        r2StorageAdaptiveGroups(
          limit: 1
          filter: { date_geq: $start, date_leq: $end, bucketName: $bucket }
        ) {
          max { payloadSize }
        }
        r2OperationsAdaptiveGroups(
          limit: 32
          filter: { date_geq: $start, date_leq: $end, bucketName: $bucket }
        ) {
          sum { requests }
          dimensions { actionType }
        }
      }
    }
  }
`;

type AnalyticsPayload = {
  data?: {
    viewer?: {
      accounts?: ReadonlyArray<{
        workersInvocationsAdaptive?: ReadonlyArray<{
          sum?: { requests?: number };
          quantiles?: { wallTimeP95?: number };
        }>;
        d1AnalyticsAdaptiveGroups?: ReadonlyArray<{
          sum?: { readQueries?: number; writeQueries?: number };
          quantiles?: { queryDurationP95?: number };
          max?: { databaseSizeBytes?: number };
        }>;
        r2StorageAdaptiveGroups?: ReadonlyArray<{
          max?: { payloadSize?: number };
        }>;
        r2OperationsAdaptiveGroups?: ReadonlyArray<{
          sum?: { requests?: number };
          dimensions?: { actionType?: string };
        }>;
      }>;
    };
  };
  errors?: ReadonlyArray<{ message?: string }>;
};

export type CloudflareAnalyticsEnv = {
  CLOUDFLARE_ACCOUNT_ID: string;
  CLOUDFLARE_API_TOKEN: string;
  CLOUDFLARE_D1_DATABASE_ID: string;
  CLOUDFLARE_R2_BUCKET_NAME: string;
};

export class CloudflareAnalyticsClient implements AnalyticsSource {
  constructor(
    private readonly env: CloudflareAnalyticsEnv,
    private readonly fetcher: typeof fetch = globalThis.fetch.bind(globalThis),
  ) {}

  async fetchSnapshot(now: Date): Promise<AnalyticsSnapshot> {
    const end = now.toISOString().slice(0, 10);
    const start = new Date(now.getTime() - ANALYTICS_WINDOW_DAYS * MS_PER_DAY)
      .toISOString()
      .slice(0, 10);

    const response = await this.fetcher(CLOUDFLARE_GRAPHQL_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.env.CLOUDFLARE_API_TOKEN}`,
      },
      body: JSON.stringify({
        query: ANALYTICS_QUERY,
        variables: {
          accountTag: this.env.CLOUDFLARE_ACCOUNT_ID,
          start,
          end,
          dbId: this.env.CLOUDFLARE_D1_DATABASE_ID,
          bucket: this.env.CLOUDFLARE_R2_BUCKET_NAME,
        },
      }),
    });

    if (!response.ok) {
      throw new Error(
        `Cloudflare Analytics request failed: ${response.status} ${response.statusText}`,
      );
    }

    const payload = (await response.json()) as AnalyticsPayload;
    if (payload.errors && payload.errors.length > 0) {
      const messages = payload.errors.map((e) => e?.message ?? 'unknown').join('; ');
      throw new Error(`Cloudflare Analytics returned errors: ${messages}`);
    }
    const account = payload.data?.viewer?.accounts?.[0];
    if (!account) {
      throw new Error('Cloudflare Analytics returned no account data');
    }

    const workers = account.workersInvocationsAdaptive?.[0];
    const d1 = account.d1AnalyticsAdaptiveGroups?.[0];
    const r2Storage = account.r2StorageAdaptiveGroups?.[0];

    let r2GetCount = 0;
    let r2PutCount = 0;
    for (const op of account.r2OperationsAdaptiveGroups ?? []) {
      const requests = op?.sum?.requests ?? 0;
      const action = op?.dimensions?.actionType;
      if (action === 'GetObject') r2GetCount = requests;
      else if (action === 'PutObject') r2PutCount = requests;
    }

    const writeTotal = d1?.sum?.writeQueries ?? 0;
    return {
      d1SizeBytes: d1?.max?.databaseSizeBytes ?? 0,
      d1WritesPerDay: Math.round(writeTotal / ANALYTICS_WINDOW_DAYS),
      d1P95QueryMs: d1?.quantiles?.queryDurationP95 ?? 0,
      workerRequestCount: workers?.sum?.requests ?? 0,
      workerP95LatencyMs: workers?.quantiles?.wallTimeP95 ?? 0,
      r2StorageBytes: r2Storage?.max?.payloadSize ?? 0,
      r2GetCount,
      r2PutCount,
    };
  }
}

// ---------- Resend mailer ----------

const RESEND_URL = 'https://api.resend.com/emails';

export type ResendEnv = {
  RESEND_API_KEY: string;
};

export class ResendMailer implements Mailer {
  constructor(
    private readonly env: ResendEnv,
    private readonly fetcher: typeof fetch = globalThis.fetch.bind(globalThis),
  ) {}

  async send(message: {
    from: string;
    to: string;
    subject: string;
    text: string;
  }): Promise<void> {
    const response = await this.fetcher(RESEND_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.env.RESEND_API_KEY}`,
      },
      body: JSON.stringify({
        from: message.from,
        to: message.to,
        subject: message.subject,
        text: message.text,
      }),
    });
    if (!response.ok) {
      const body = await response.text();
      throw new Error(`Resend send failed: ${response.status} ${body}`);
    }
  }
}

// ---------- Orchestrator ----------

export type WatchdogResult = {
  flags: Flag[];
  metrics: Metrics;
  severity: Severity;
  emailSent: boolean;
};

export type RunWatchdogDeps = {
  db: D1Database;
  analytics: AnalyticsSource;
  mailer: Mailer;
  operatorEmail: string;
  fromEmail: string;
  now?: () => Date;
};

export async function runWatchdog(deps: RunWatchdogDeps): Promise<WatchdogResult> {
  const now = deps.now?.() ?? new Date();
  // allSettled (rather than Promise.all) so that a transient
  // analytics-API failure doesn't orphan the in-flight D1 query —
  // we always wait for both to finish, then surface the first
  // rejection. Without this, the test runner sees a pending D1
  // request leaking across the test boundary.
  const settled = await Promise.allSettled([
    gatherDbMetrics(deps.db, now),
    deps.analytics.fetchSnapshot(now),
  ]);
  for (const outcome of settled) {
    if (outcome.status === 'rejected') {
      throw outcome.reason;
    }
  }
  const dbMetrics = (settled[0] as PromiseFulfilledResult<DbMetrics>).value;
  const snapshot = (settled[1] as PromiseFulfilledResult<AnalyticsSnapshot>).value;
  const metrics: Metrics = { ...dbMetrics, ...snapshot };
  const flags = computeFlags(metrics);
  const severity = highestSeverity(flags);

  if (flags.length === 0) {
    return { flags, metrics, severity, emailSent: false };
  }

  const { subject, text } = buildEmail(flags, metrics, now);
  await deps.mailer.send({
    from: deps.fromEmail,
    to: deps.operatorEmail,
    subject,
    text,
  });
  return { flags, metrics, severity, emailSent: true };
}

// ---------- Scheduled-handler wiring ----------

export type WatchdogEnv = CloudflareAnalyticsEnv & ResendEnv & {
  FORUM_DB: D1Database;
  RESEND_FROM_EMAIL: string;
  RESEND_TO_EMAIL: string;
};

export async function handleScheduled(env: WatchdogEnv): Promise<WatchdogResult> {
  const analytics = new CloudflareAnalyticsClient({
    CLOUDFLARE_ACCOUNT_ID: env.CLOUDFLARE_ACCOUNT_ID,
    CLOUDFLARE_API_TOKEN: env.CLOUDFLARE_API_TOKEN,
    CLOUDFLARE_D1_DATABASE_ID: env.CLOUDFLARE_D1_DATABASE_ID,
    CLOUDFLARE_R2_BUCKET_NAME: env.CLOUDFLARE_R2_BUCKET_NAME,
  });
  const mailer = new ResendMailer({ RESEND_API_KEY: env.RESEND_API_KEY });
  return runWatchdog({
    db: env.FORUM_DB,
    analytics,
    mailer,
    operatorEmail: env.RESEND_TO_EMAIL,
    fromEmail: env.RESEND_FROM_EMAIL,
  });
}

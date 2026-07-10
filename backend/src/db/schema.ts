import { relations, sql } from 'drizzle-orm';
import {
  check,
  index,
  integer,
  primaryKey,
  sqliteTable,
  text,
  uniqueIndex,
} from 'drizzle-orm/sqlite-core';

const uuidColumn = (name?: string) =>
  (name ? text(name) : text()).$defaultFn(() => crypto.randomUUID());

const timestampColumn = (name: string) =>
  integer(name, { mode: 'timestamp_ms' }).$defaultFn(() => new Date());

export const MAX_COMMENT_DEPTH = 6;

export const profiles = sqliteTable(
  'profiles',
  {
    id: uuidColumn().primaryKey(),
    displayName: text('display_name').notNull(),
    username: text('username'),
    avatarUrl: text('avatar_url'),
    joinedAt: timestampColumn('joined_at').notNull(),
    role: text().notNull().default('user'),
    careblazersUserId: text('careblazers_user_id').notNull(),
  },
  (t) => [
    uniqueIndex('profiles_careblazers_user_id_unique').on(t.careblazersUserId),
    uniqueIndex('profiles_username_unique').on(t.username),
  ],
);

export const circles = sqliteTable(
  'circles',
  {
    id: uuidColumn().primaryKey(),
    name: text().notNull(),
    ownerProfileId: text('owner_profile_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    createdAt: timestampColumn('created_at').notNull(),
    // Per-circle monotonic revision source. Every accepted sync write
    // does rev = ++syncCounter, making rev strictly increasing per
    // circle and skew-proof (unlike wall-clock) for delta pull.
    syncCounter: integer('sync_counter').notNull().default(0),
  },
  (t) => [index('circles_owner_profile_id_idx').on(t.ownerProfileId)],
);

// The shared loved one — one per circle. The payload is an opaque JSON
// blob the server never parses; clientUpdatedAt drives last-write-wins;
// rev is the server-assigned per-circle delta cursor.
export const patients = sqliteTable(
  'patients',
  {
    id: uuidColumn().primaryKey(),
    circleId: text('circle_id')
      .notNull()
      .references(() => circles.id, { onDelete: 'cascade' }),
    payload: text().notNull(),
    clientUpdatedAt: integer('client_updated_at').notNull(),
    rev: integer().notNull(),
    deleted: integer({ mode: 'boolean' }).notNull().default(false),
  },
  (t) => [uniqueIndex('patients_circle_unique').on(t.circleId)],
);

// Every other synced care entity (medications, dose windows, routines,
// tasks, health logs, appointments, journal, …) stored generically.
// `id` is the client-generated, globally-unique entity id. `collection`
// is an opaque taxonomy string the app owns. `payload` is opaque JSON.
export const careDocs = sqliteTable(
  'care_docs',
  {
    // Doc ids are CLIENT-minted, so they are only unique within the
    // pushing device's world — two circles can legitimately carry the
    // same id (e.g. seeded demo datasets). The primary key is therefore
    // composite (id, circle_id): every circle owns its own namespace and
    // a push can never read or overwrite another circle's row.
    id: text().notNull(),
    circleId: text('circle_id')
      .notNull()
      .references(() => circles.id, { onDelete: 'cascade' }),
    collection: text().notNull(),
    payload: text().notNull(),
    clientUpdatedAt: integer('client_updated_at').notNull(),
    rev: integer().notNull(),
    deleted: integer({ mode: 'boolean' }).notNull().default(false),
  },
  (t) => [
    primaryKey({ columns: [t.id, t.circleId] }),
    index('care_docs_circle_rev_idx').on(t.circleId, t.rev),
    index('care_docs_circle_collection_idx').on(t.circleId, t.collection),
  ],
);

export const circleMembers = sqliteTable(
  'circle_members',
  {
    id: uuidColumn().primaryKey(),
    circleId: text('circle_id')
      .notNull()
      .references(() => circles.id, { onDelete: 'cascade' }),
    profileId: text('profile_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    role: text().notNull().default('member'),
    joinedAt: timestampColumn('joined_at').notNull(),
  },
  (t) => [
    uniqueIndex('circle_members_circle_profile_unique').on(
      t.circleId,
      t.profileId,
    ),
    index('circle_members_circle_id_idx').on(t.circleId),
    index('circle_members_profile_id_idx').on(t.profileId),
    check(
      'circle_members_role_enum',
      sql`${t.role} IN ('owner', 'member', 'viewer')`,
    ),
  ],
);

export const circleInvites = sqliteTable(
  'circle_invites',
  {
    token: text().primaryKey(),
    circleId: text('circle_id')
      .notNull()
      .references(() => circles.id, { onDelete: 'cascade' }),
    createdByProfileId: text('created_by_profile_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    createdAt: timestampColumn('created_at').notNull(),
    expiresAt: integer('expires_at', { mode: 'timestamp_ms' }).notNull(),
    revoked: integer({ mode: 'boolean' }).notNull().default(false),
    // Single-use consumption (2026-06-11): set atomically when a NEW
    // member redeems the invite. A consumed invite admits no one else —
    // a forwarded/leaked link can't quietly grow the circle. Null =
    // still redeemable.
    usedAt: integer('used_at', { mode: 'timestamp_ms' }),
    usedByProfileId: text('used_by_profile_id').references(
      () => profiles.id,
      { onDelete: 'set null' },
    ),
  },
  (t) => [index('circle_invites_circle_id_idx').on(t.circleId)],
);

export const posts = sqliteTable(
  'posts',
  {
    id: uuidColumn().primaryKey(),
    authorId: text('author_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    title: text().notNull(),
    body: text().notNull(),
    createdAt: timestampColumn('created_at').notNull(),
    updatedAt: timestampColumn('updated_at').notNull(),
    voteCount: integer('vote_count').notNull().default(0),
    hidden: integer({ mode: 'boolean' }).notNull().default(false),
    crisisFlagged: integer('crisis_flagged', { mode: 'boolean' })
      .notNull()
      .default(false),
  },
  (t) => [
    index('posts_author_id_idx').on(t.authorId),
    index('posts_created_at_idx').on(t.createdAt),
  ],
);

export const comments = sqliteTable(
  'comments',
  {
    id: uuidColumn().primaryKey(),
    postId: text('post_id')
      .notNull()
      .references(() => posts.id, { onDelete: 'cascade' }),
    authorId: text('author_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    parentCommentId: text('parent_comment_id').references(
      (): any => comments.id,
      { onDelete: 'cascade' },
    ),
    body: text().notNull(),
    createdAt: timestampColumn('created_at').notNull(),
    voteCount: integer('vote_count').notNull().default(0),
    depth: integer().notNull().default(0),
    hidden: integer({ mode: 'boolean' }).notNull().default(false),
    crisisFlagged: integer('crisis_flagged', { mode: 'boolean' })
      .notNull()
      .default(false),
  },
  (t) => [
    index('comments_post_id_idx').on(t.postId),
    index('comments_parent_comment_id_idx').on(t.parentCommentId),
    check(
      'comments_depth_range',
      sql`${t.depth} >= 0 AND ${t.depth} <= ${sql.raw(String(MAX_COMMENT_DEPTH))}`,
    ),
  ],
);

export const VOTE_TARGET_POST = 'post';
export const VOTE_TARGET_COMMENT = 'comment';

export const votes = sqliteTable(
  'votes',
  {
    id: uuidColumn().primaryKey(),
    voterId: text('voter_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    targetKind: text('target_kind').notNull(),
    targetId: text('target_id').notNull(),
    value: integer().notNull(),
    createdAt: timestampColumn('created_at').notNull(),
  },
  (t) => [
    uniqueIndex('votes_voter_target_unique').on(
      t.voterId,
      t.targetKind,
      t.targetId,
    ),
    check('votes_value_range', sql`${t.value} = 1 OR ${t.value} = -1`),
    check(
      'votes_target_kind_enum',
      sql`${t.targetKind} IN ('post', 'comment')`,
    ),
  ],
);

export const REPORT_STATUS_PENDING = 'pending';
export const REPORT_STATUS_REVIEWED = 'reviewed';
export const REPORT_STATUS_ACTIONED = 'actioned';

export const reports = sqliteTable(
  'reports',
  {
    id: uuidColumn().primaryKey(),
    targetKind: text('target_kind').notNull(),
    targetId: text('target_id').notNull(),
    reporterId: text('reporter_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    reason: text().notNull(),
    status: text().notNull().default(REPORT_STATUS_PENDING),
    createdAt: timestampColumn('created_at').notNull(),
    resolvedAt: integer('resolved_at', { mode: 'timestamp_ms' }),
  },
  (t) => [
    index('reports_status_idx').on(t.status),
    index('reports_target_idx').on(t.targetKind, t.targetId),
    check(
      'reports_target_kind_enum',
      sql`${t.targetKind} IN ('post', 'comment')`,
    ),
    check(
      'reports_status_enum',
      sql`${t.status} IN ('pending', 'reviewed', 'actioned')`,
    ),
  ],
);

// Per-call LLM usage ledger. One row per /chat completion: who, when,
// which model, the real token counts the inference host returns, and the
// derived cost in MICRO-DOLLARS ($1 = 1_000_000), stored as an integer so
// summing for the daily caps can't drift. This table is the single source
// of truth for three things: (a) per-user daily token quotas, (b) the
// global daily spend circuit breaker, and (c) raw cost measurement. It
// stores token COUNTS only — never prompt/response text (that's PHI and
// the host already saw it; we don't need a second copy).
export const llmUsage = sqliteTable(
  'llm_usage',
  {
    id: uuidColumn().primaryKey(),
    userId: text('user_id').notNull(),
    createdAt: timestampColumn('created_at').notNull(),
    model: text().notNull(),
    // Which app surface drove this call ('chat' | 'recap' | …). One
    // endpoint serves every LLM feature; this tag is what lets cost
    // reporting split spend per surface without separate routes.
    feature: text().notNull().default('chat'),
    promptTokens: integer('prompt_tokens').notNull().default(0),
    completionTokens: integer('completion_tokens').notNull().default(0),
    costMicros: integer('cost_micros').notNull().default(0),
  },
  (t) => [
    // The per-user daily quota query: WHERE user_id = ? AND created_at >= ?
    index('llm_usage_user_created_idx').on(t.userId, t.createdAt),
    // The global daily spend query: WHERE created_at >= ?
    index('llm_usage_created_idx').on(t.createdAt),
  ],
);

export type LlmUsage = typeof llmUsage.$inferSelect;

// Server-side subscription entitlement — the AUTHORITATIVE record of whether
// a user has premium, one row per user keyed by the forum JWT `sub` (the
// `careblazers_user_id`). The device NEVER decides its own entitlement: it
// posts a store receipt (Apple JWS / Google purchaseToken) to
// POST /billing/verify, the Worker validates it against the platform store
// API, and this row is upserted. GET /billing/entitlement then reads this row
// as the launch-time source of truth. `latestReceipt` retains the last
// verified token so a future re-check (renewal, refund) can re-validate
// without another device round-trip.
export const entitlements = sqliteTable(
  'entitlements',
  {
    // The forum JWT sub / careblazers_user_id. One entitlement per user.
    userId: text('user_id').primaryKey(),
    platform: text().notNull(),
    productId: text('product_id').notNull(),
    status: text().notNull().default('none'),
    // Subscription expiry in ms epoch; null for a non-expiring product or
    // when the store gives no expiry (treated as "no expiry" by isPremium).
    expiresAt: integer('expires_at'),
    environment: text().notNull().default('production'),
    // The last verified token/JWS (Apple signed transaction or Google
    // purchaseToken) — kept for server-side re-checks.
    latestReceipt: text('latest_receipt'),
    updatedAt: timestampColumn('updated_at').notNull(),
    createdAt: timestampColumn('created_at').notNull(),
  },
  (t) => [
    check('entitlements_platform_enum', sql`${t.platform} IN ('ios', 'android')`),
    check(
      'entitlements_status_enum',
      sql`${t.status} IN ('active', 'expired', 'trial', 'none')`,
    ),
    check(
      'entitlements_environment_enum',
      sql`${t.environment} IN ('production', 'sandbox')`,
    ),
  ],
);

export type Entitlement = typeof entitlements.$inferSelect;
export type NewEntitlement = typeof entitlements.$inferInsert;

export const profilesRelations = relations(profiles, ({ many }) => ({
  posts: many(posts),
  comments: many(comments),
  votes: many(votes),
  reports: many(reports),
  ownedCircles: many(circles),
  circleMemberships: many(circleMembers),
}));

export const circlesRelations = relations(circles, ({ one, many }) => ({
  owner: one(profiles, {
    fields: [circles.ownerProfileId],
    references: [profiles.id],
  }),
  members: many(circleMembers),
  invites: many(circleInvites),
  patient: one(patients),
  careDocs: many(careDocs),
}));

export const patientsRelations = relations(patients, ({ one }) => ({
  circle: one(circles, {
    fields: [patients.circleId],
    references: [circles.id],
  }),
}));

export const careDocsRelations = relations(careDocs, ({ one }) => ({
  circle: one(circles, {
    fields: [careDocs.circleId],
    references: [circles.id],
  }),
}));

export const circleMembersRelations = relations(circleMembers, ({ one }) => ({
  circle: one(circles, {
    fields: [circleMembers.circleId],
    references: [circles.id],
  }),
  profile: one(profiles, {
    fields: [circleMembers.profileId],
    references: [profiles.id],
  }),
}));

export const circleInvitesRelations = relations(circleInvites, ({ one }) => ({
  circle: one(circles, {
    fields: [circleInvites.circleId],
    references: [circles.id],
  }),
  createdBy: one(profiles, {
    fields: [circleInvites.createdByProfileId],
    references: [profiles.id],
  }),
}));

export const postsRelations = relations(posts, ({ one, many }) => ({
  author: one(profiles, {
    fields: [posts.authorId],
    references: [profiles.id],
  }),
  comments: many(comments),
}));

export const commentsRelations = relations(comments, ({ one, many }) => ({
  post: one(posts, { fields: [comments.postId], references: [posts.id] }),
  author: one(profiles, {
    fields: [comments.authorId],
    references: [profiles.id],
  }),
  parent: one(comments, {
    fields: [comments.parentCommentId],
    references: [comments.id],
    relationName: 'comment_parent',
  }),
  replies: many(comments, { relationName: 'comment_parent' }),
}));

export const votesRelations = relations(votes, ({ one }) => ({
  voter: one(profiles, {
    fields: [votes.voterId],
    references: [profiles.id],
  }),
}));

export const reportsRelations = relations(reports, ({ one }) => ({
  reporter: one(profiles, {
    fields: [reports.reporterId],
    references: [profiles.id],
  }),
}));

export type Profile = typeof profiles.$inferSelect;
export type NewProfile = typeof profiles.$inferInsert;
export type Post = typeof posts.$inferSelect;
export type NewPost = typeof posts.$inferInsert;
export type Comment = typeof comments.$inferSelect;
export type NewComment = typeof comments.$inferInsert;
export type Vote = typeof votes.$inferSelect;
export type NewVote = typeof votes.$inferInsert;
export type Report = typeof reports.$inferSelect;
export type NewReport = typeof reports.$inferInsert;
export type Circle = typeof circles.$inferSelect;
export type NewCircle = typeof circles.$inferInsert;
export type CircleMember = typeof circleMembers.$inferSelect;
export type NewCircleMember = typeof circleMembers.$inferInsert;
export type CircleInvite = typeof circleInvites.$inferSelect;
export type NewCircleInvite = typeof circleInvites.$inferInsert;
export type Patient = typeof patients.$inferSelect;
export type NewPatient = typeof patients.$inferInsert;
export type CareDoc = typeof careDocs.$inferSelect;
export type NewCareDoc = typeof careDocs.$inferInsert;

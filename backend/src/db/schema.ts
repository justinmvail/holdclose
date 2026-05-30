import { relations, sql } from 'drizzle-orm';
import {
  check,
  index,
  integer,
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
    avatarUrl: text('avatar_url'),
    joinedAt: timestampColumn('joined_at').notNull(),
    role: text().notNull().default('user'),
    careblazersUserId: text('careblazers_user_id').notNull(),
  },
  (t) => [
    uniqueIndex('profiles_careblazers_user_id_unique').on(t.careblazersUserId),
  ],
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

export const profilesRelations = relations(profiles, ({ many }) => ({
  posts: many(posts),
  comments: many(comments),
  votes: many(votes),
  reports: many(reports),
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

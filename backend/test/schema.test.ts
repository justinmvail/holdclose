import { env } from 'cloudflare:test';
import { drizzle } from 'drizzle-orm/d1';
import { and, eq } from 'drizzle-orm';
import { beforeEach, describe, expect, it } from 'vitest';

import {
  MAX_COMMENT_DEPTH,
  REPORT_STATUS_PENDING,
  VOTE_TARGET_COMMENT,
  VOTE_TARGET_POST,
  comments,
  posts,
  profiles,
  reports,
  votes,
} from '../src/db/schema';

const db = () => drizzle(env.FORUM_DB);

async function clearTables() {
  await env.FORUM_DB.batch([
    env.FORUM_DB.prepare('DELETE FROM reports'),
    env.FORUM_DB.prepare('DELETE FROM votes'),
    env.FORUM_DB.prepare('DELETE FROM comments'),
    env.FORUM_DB.prepare('DELETE FROM posts'),
    env.FORUM_DB.prepare('DELETE FROM profiles'),
  ]);
}

async function seedProfile(overrides: Partial<typeof profiles.$inferInsert> = {}) {
  const [row] = await db()
    .insert(profiles)
    .values({
      displayName: 'Caregiver_ab12cd',
      holdcloseUserId: `cb-${crypto.randomUUID()}`,
      ...overrides,
    })
    .returning();
  return row;
}

async function seedPost(
  authorId: string,
  overrides: Partial<typeof posts.$inferInsert> = {},
) {
  const [row] = await db()
    .insert(posts)
    .values({
      authorId,
      title: 'How do you handle sundowning?',
      body: 'My mom gets agitated every evening around 5pm and I am at a loss.',
      ...overrides,
    })
    .returning();
  return row;
}

async function seedComment(
  postId: string,
  authorId: string,
  overrides: Partial<typeof comments.$inferInsert> = {},
) {
  const [row] = await db()
    .insert(comments)
    .values({
      postId,
      authorId,
      body: 'Lowering the lights an hour before sunset helped us a lot.',
      ...overrides,
    })
    .returning();
  return row;
}

describe('forum schema round-trip', () => {
  beforeEach(async () => {
    await clearTables();
  });

  describe('profiles', () => {
    it('round-trips a profile with defaults', async () => {
      const profile = await seedProfile();

      expect(profile.id).toMatch(/^[0-9a-f-]{36}$/);
      expect(profile.role).toBe('user');
      expect(profile.joinedAt).toBeInstanceOf(Date);
      expect(profile.avatarUrl).toBeNull();

      const [readBack] = await db()
        .select()
        .from(profiles)
        .where(eq(profiles.id, profile.id));
      expect(readBack.displayName).toBe('Caregiver_ab12cd');
      expect(readBack.holdcloseUserId).toBe(profile.holdcloseUserId);
    });

    it('rejects a duplicate holdclose_user_id', async () => {
      const first = await seedProfile();
      await expect(
        seedProfile({ holdcloseUserId: first.holdcloseUserId }),
      ).rejects.toThrow();
    });
  });

  describe('posts', () => {
    it('defaults vote_count to 0 and hidden to false', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);

      expect(post.voteCount).toBe(0);
      expect(post.hidden).toBe(false);
      expect(post.createdAt).toBeInstanceOf(Date);
      expect(post.updatedAt).toBeInstanceOf(Date);
    });

    it('cascades deletes from profiles', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);

      await db().delete(profiles).where(eq(profiles.id, profile.id));

      const orphan = await db()
        .select()
        .from(posts)
        .where(eq(posts.id, post.id));
      expect(orphan).toHaveLength(0);
    });
  });

  describe('comments', () => {
    it('allows nesting up to depth 6', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);

      let parentId: string | null = null;
      for (let depth = 0; depth <= MAX_COMMENT_DEPTH; depth++) {
        const inserted = await seedComment(post.id, profile.id, {
          parentCommentId: parentId,
          depth,
        });
        expect(inserted.depth).toBe(depth);
        parentId = inserted.id;
      }

      const rows = await db()
        .select()
        .from(comments)
        .where(eq(comments.postId, post.id));
      expect(rows).toHaveLength(MAX_COMMENT_DEPTH + 1);
    });

    it('rejects a comment past the depth cap (depth 7)', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);

      await expect(
        seedComment(post.id, profile.id, {
          depth: MAX_COMMENT_DEPTH + 1,
        }),
      ).rejects.toThrow();
    });

    it('rejects a negative depth', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);

      await expect(
        seedComment(post.id, profile.id, { depth: -1 }),
      ).rejects.toThrow();
    });
  });

  describe('votes', () => {
    it('round-trips a +1 post vote', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);

      const [vote] = await db()
        .insert(votes)
        .values({
          voterId: profile.id,
          targetKind: VOTE_TARGET_POST,
          targetId: post.id,
          value: 1,
        })
        .returning();

      expect(vote.value).toBe(1);
      expect(vote.targetKind).toBe(VOTE_TARGET_POST);
    });

    it('enforces unique (voter_id, target_kind, target_id)', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);

      await db().insert(votes).values({
        voterId: profile.id,
        targetKind: VOTE_TARGET_POST,
        targetId: post.id,
        value: 1,
      });

      await expect(
        db().insert(votes).values({
          voterId: profile.id,
          targetKind: VOTE_TARGET_POST,
          targetId: post.id,
          value: -1,
        }),
      ).rejects.toThrow();
    });

    it('allows the same voter to vote on a post and a comment with the same target_id collision-safety', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);
      const comment = await seedComment(post.id, profile.id);

      await db().insert(votes).values({
        voterId: profile.id,
        targetKind: VOTE_TARGET_POST,
        targetId: post.id,
        value: 1,
      });
      await db().insert(votes).values({
        voterId: profile.id,
        targetKind: VOTE_TARGET_COMMENT,
        targetId: comment.id,
        value: 1,
      });

      const rows = await db()
        .select()
        .from(votes)
        .where(eq(votes.voterId, profile.id));
      expect(rows).toHaveLength(2);
    });

    it('rejects a value outside ±1', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);

      await expect(
        db().insert(votes).values({
          voterId: profile.id,
          targetKind: VOTE_TARGET_POST,
          targetId: post.id,
          value: 5,
        }),
      ).rejects.toThrow();
    });

    it('rejects an unknown target_kind', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);

      await expect(
        db().insert(votes).values({
          voterId: profile.id,
          targetKind: 'reaction',
          targetId: post.id,
          value: 1,
        }),
      ).rejects.toThrow();
    });
  });

  describe('reports', () => {
    it('defaults status to pending and resolved_at to null', async () => {
      const reporter = await seedProfile();
      const author = await seedProfile({
        holdcloseUserId: `cb-${crypto.randomUUID()}`,
      });
      const post = await seedPost(author.id);

      const [report] = await db()
        .insert(reports)
        .values({
          reporterId: reporter.id,
          targetKind: VOTE_TARGET_POST,
          targetId: post.id,
          reason: 'spam',
        })
        .returning();

      expect(report.status).toBe(REPORT_STATUS_PENDING);
      expect(report.resolvedAt).toBeNull();
    });

    it('rejects an unknown status', async () => {
      const reporter = await seedProfile();
      const author = await seedProfile({
        holdcloseUserId: `cb-${crypto.randomUUID()}`,
      });
      const post = await seedPost(author.id);

      await expect(
        db().insert(reports).values({
          reporterId: reporter.id,
          targetKind: VOTE_TARGET_POST,
          targetId: post.id,
          reason: 'spam',
          status: 'shrug',
        }),
      ).rejects.toThrow();
    });
  });

  describe('relations', () => {
    it('joins a post to its author and comments', async () => {
      const profile = await seedProfile();
      const post = await seedPost(profile.id);
      await seedComment(post.id, profile.id, { body: 'a' });
      await seedComment(post.id, profile.id, { body: 'b' });

      const rows = await db()
        .select({
          postId: posts.id,
          author: profiles.displayName,
          commentBody: comments.body,
        })
        .from(posts)
        .innerJoin(profiles, eq(profiles.id, posts.authorId))
        .innerJoin(
          comments,
          and(eq(comments.postId, posts.id), eq(comments.authorId, profile.id)),
        );

      expect(rows).toHaveLength(2);
      expect(rows.every((r) => r.author === 'Caregiver_ab12cd')).toBe(true);
    });
  });
});

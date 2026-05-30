import { and, count, eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import { comments, posts, profiles, type Profile } from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

export type ProfilesBindings = AuthBindings & {
  FORUM_DB: D1Database;
  // Public origin of the R2 bucket fronting avatar uploads (e.g.
  // `https://media.careblazers.local`). avatar_url updates must start
  // with this prefix so the API can't be used to point at arbitrary
  // off-platform images.
  R2_PUBLIC_URL: string;
};

export type ProfilesVariables = AuthVariables;

const DISPLAY_NAME_PATTERN = /^[A-Za-z0-9_]{3,30}$/;

// Conservative wordlist meant as a first line of defense, not exhaustive
// moderation. Substring match against the lowercased display name.
const PROFANITY_WORDLIST = [
  'fuck',
  'shit',
  'bitch',
  'cunt',
  'asshole',
  'nigger',
  'faggot',
  'whore',
  'slut',
  'dick',
];

const containsProfanity = (name: string): boolean => {
  const lower = name.toLowerCase();
  return PROFANITY_WORDLIST.some((word) => lower.includes(word));
};

// Deterministic 6-hex-char hash of the careblazers_user_id so a retried
// bootstrap call produces the same default name.
async function defaultDisplayName(careblazersUserId: string): Promise<string> {
  const bytes = new TextEncoder().encode(careblazersUserId);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  const hex = Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return `Caregiver_${hex.slice(0, 6)}`;
}

function meResponse(profile: Profile) {
  return {
    id: profile.id,
    careblazers_user_id: profile.careblazersUserId,
    display_name: profile.displayName,
    avatar_url: profile.avatarUrl,
    joined_at: profile.joinedAt.toISOString(),
    role: profile.role,
  };
}

export const profilesRouter = () => {
  const router = new Hono<{
    Bindings: ProfilesBindings;
    Variables: ProfilesVariables;
  }>();

  router.post('/bootstrap', async (c) => {
    const careblazersUserId = c.get('userId');
    const db = drizzle(c.env.FORUM_DB);

    const [existing] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.careblazersUserId, careblazersUserId));
    if (existing) {
      return c.json(meResponse(existing), 200);
    }

    const displayName = await defaultDisplayName(careblazersUserId);
    const [created] = await db
      .insert(profiles)
      .values({ displayName, careblazersUserId })
      .returning();
    return c.json(meResponse(created), 201);
  });

  router.get('/me', async (c) => {
    const careblazersUserId = c.get('userId');
    const db = drizzle(c.env.FORUM_DB);

    const [profile] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.careblazersUserId, careblazersUserId));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }
    return c.json(meResponse(profile), 200);
  });

  router.patch('/me', async (c) => {
    const careblazersUserId = c.get('userId');
    const db = drizzle(c.env.FORUM_DB);

    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_body' }, 400);
    }
    if (!body || typeof body !== 'object') {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const patch = body as { display_name?: unknown; avatar_url?: unknown };
    const updates: { displayName?: string; avatarUrl?: string } = {};

    if (patch.display_name !== undefined) {
      if (
        typeof patch.display_name !== 'string' ||
        !DISPLAY_NAME_PATTERN.test(patch.display_name)
      ) {
        return c.json({ error: 'invalid_display_name' }, 400);
      }
      if (containsProfanity(patch.display_name)) {
        return c.json({ error: 'profanity_blocked' }, 400);
      }
      updates.displayName = patch.display_name;
    }

    if (patch.avatar_url !== undefined) {
      const origin = c.env.R2_PUBLIC_URL;
      if (
        typeof patch.avatar_url !== 'string' ||
        !origin ||
        !patch.avatar_url.startsWith(origin)
      ) {
        return c.json({ error: 'invalid_avatar_url' }, 400);
      }
      updates.avatarUrl = patch.avatar_url;
    }

    if (Object.keys(updates).length === 0) {
      return c.json({ error: 'no_fields_to_update' }, 400);
    }

    const [updated] = await db
      .update(profiles)
      .set(updates)
      .where(eq(profiles.careblazersUserId, careblazersUserId))
      .returning();
    if (!updated) {
      return c.json({ error: 'profile_not_found' }, 404);
    }
    return c.json(meResponse(updated), 200);
  });

  router.get('/:id', async (c) => {
    const id = c.req.param('id');
    const db = drizzle(c.env.FORUM_DB);

    const [profile] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.id, id));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    const [postCountRow] = await db
      .select({ value: count() })
      .from(posts)
      .where(and(eq(posts.authorId, id), eq(posts.hidden, false)));
    const [commentCountRow] = await db
      .select({ value: count() })
      .from(comments)
      .where(and(eq(comments.authorId, id), eq(comments.hidden, false)));

    return c.json(
      {
        id: profile.id,
        display_name: profile.displayName,
        avatar_url: profile.avatarUrl,
        joined_at: profile.joinedAt.toISOString(),
        post_count: postCountRow?.value ?? 0,
        comment_count: commentCountRow?.value ?? 0,
      },
      200,
    );
  });

  return router;
};

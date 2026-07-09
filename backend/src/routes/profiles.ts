import { and, count, eq, inArray, ne } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import {
  careDocs,
  circleInvites,
  circleMembers,
  circles,
  comments,
  llmUsage,
  patients,
  posts,
  profiles,
  reports,
  votes,
  type Profile,
} from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

export type ProfilesBindings = AuthBindings & {
  FORUM_DB: D1Database;
  // Public origin of the R2 bucket fronting avatar uploads (e.g.
  // `https://media.holdclose.local`). avatar_url updates must start
  // with this prefix so the API can't be used to point at arbitrary
  // off-platform images.
  R2_PUBLIC_URL: string;
  // Document-scan blobs (emergency card / POA / ID images), namespaced
  // per circle under `documents/<circleId>/`. Account deletion purges the
  // blobs of every circle it tears down so no synced PHI outlives the
  // account.
  DOC_BLOBS: R2Bucket;
};

export type ProfilesVariables = AuthVariables;

const DISPLAY_NAME_PATTERN = /^[A-Za-z0-9_]{3,30}$/;
const USERNAME_PATTERN = /^[a-z0-9_]{3,20}$/;

// The shape `defaultDisplayName` mints: `Caregiver_` + 6 lowercase hex
// chars. Used to decide whether a profile's display_name is still the
// auto-generated default (and therefore safe to overwrite with a
// freshly-set username) vs. a name the caregiver explicitly customized.
const DEFAULT_DISPLAY_NAME_PATTERN = /^Caregiver_[0-9a-f]{6}$/;

const isDefaultDisplayName = (name: string): boolean =>
  DEFAULT_DISPLAY_NAME_PATTERN.test(name);

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
    username: profile.username ?? null,
    avatar_url: profile.avatarUrl,
    joined_at: profile.joinedAt.toISOString(),
    role: profile.role,
  };
}

type Db = ReturnType<typeof drizzle>;

// Delete every R2 object under a circle's document namespace. R2 `list`
// is paginated + capped at 1000 keys/page, so page through until the
// listing is no longer truncated. Deleting a namespace with no objects
// is a no-op.
async function purgeCircleBlobs(
  blobs: R2Bucket,
  circleId: string,
): Promise<number> {
  const prefix = `documents/${circleId}/`;
  let deleted = 0;
  let cursor: string | undefined;
  do {
    const listed = await blobs.list({ prefix, cursor });
    const keys = listed.objects.map((o) => o.key);
    if (keys.length > 0) {
      await blobs.delete(keys);
      deleted += keys.length;
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  return deleted;
}

type DeletionSummary = {
  profiles: number;
  posts: number;
  comments: number;
  votes: number;
  reports: number;
  circles_owned: number;
  circles_transferred: number;
  circle_memberships: number;
  patients: number;
  care_docs: number;
  document_blobs: number;
  llm_usage: number;
};

// Hard-delete an account and everything tied to it. Ordered so a row is
// only removed after the rows that reference it, since D1 does not enforce
// FK cascades (see the DELETE /me comment). `profileId` keys the forum +
// circle data; `careblazersUserId` is the JWT `sub` that keys llm_usage.
async function deleteAccount(
  db: Db,
  blobs: R2Bucket,
  profileId: string,
  careblazersUserId: string,
): Promise<DeletionSummary> {
  const summary: DeletionSummary = {
    profiles: 0,
    posts: 0,
    comments: 0,
    votes: 0,
    reports: 0,
    circles_owned: 0,
    circles_transferred: 0,
    circle_memberships: 0,
    patients: 0,
    care_docs: 0,
    document_blobs: 0,
    llm_usage: 0,
  };

  // --- Forum content the caller authored ------------------------------
  // Comments before posts: a comment on the caller's own post would
  // otherwise reference a post we just removed. Votes + reports are
  // standalone rows keyed by the actor.
  const deletedComments = await db
    .delete(comments)
    .where(eq(comments.authorId, profileId))
    .returning({ id: comments.id });
  summary.comments = deletedComments.length;

  const deletedPosts = await db
    .delete(posts)
    .where(eq(posts.authorId, profileId))
    .returning({ id: posts.id });
  summary.posts = deletedPosts.length;

  const deletedVotes = await db
    .delete(votes)
    .where(eq(votes.voterId, profileId))
    .returning({ id: votes.id });
  summary.votes = deletedVotes.length;

  const deletedReports = await db
    .delete(reports)
    .where(eq(reports.reporterId, profileId))
    .returning({ id: reports.id });
  summary.reports = deletedReports.length;

  // --- Circles the caller owns ----------------------------------------
  // A circle the caller SOLELY owns is torn down with all its care data +
  // blobs. A circle with OTHER members has ownership transferred to one of
  // them so the shared loved-one record survives the account deletion.
  const owned = await db
    .select({ id: circles.id })
    .from(circles)
    .where(eq(circles.ownerProfileId, profileId));

  const soleOwnedIds: string[] = [];
  for (const { id: circleId } of owned) {
    const others = await db
      .select({ profileId: circleMembers.profileId })
      .from(circleMembers)
      .where(
        and(
          eq(circleMembers.circleId, circleId),
          ne(circleMembers.profileId, profileId),
        ),
      );
    if (others.length === 0) {
      soleOwnedIds.push(circleId);
    } else {
      // Promote the first remaining member to owner (both the circle's
      // owner pointer and their membership role).
      const heirId = others[0].profileId;
      await db
        .update(circles)
        .set({ ownerProfileId: heirId })
        .where(eq(circles.id, circleId));
      await db
        .update(circleMembers)
        .set({ role: 'owner' })
        .where(
          and(
            eq(circleMembers.circleId, circleId),
            eq(circleMembers.profileId, heirId),
          ),
        );
      summary.circles_transferred += 1;
    }
  }

  // --- Solely-owned circles: purge care data + blobs, then the circle --
  if (soleOwnedIds.length > 0) {
    for (const circleId of soleOwnedIds) {
      summary.document_blobs += await purgeCircleBlobs(blobs, circleId);
    }

    const deletedCareDocs = await db
      .delete(careDocs)
      .where(inArray(careDocs.circleId, soleOwnedIds))
      .returning({ id: careDocs.id });
    summary.care_docs = deletedCareDocs.length;

    const deletedPatients = await db
      .delete(patients)
      .where(inArray(patients.circleId, soleOwnedIds))
      .returning({ id: patients.id });
    summary.patients = deletedPatients.length;

    await db
      .delete(circleInvites)
      .where(inArray(circleInvites.circleId, soleOwnedIds));

    await db
      .delete(circleMembers)
      .where(inArray(circleMembers.circleId, soleOwnedIds));

    const deletedCircles = await db
      .delete(circles)
      .where(inArray(circles.id, soleOwnedIds))
      .returning({ id: circles.id });
    summary.circles_owned = deletedCircles.length;
  }

  // --- Any remaining memberships in circles that outlive the caller ----
  // Memberships in a solely-owned circle were already dropped with that
  // circle above; this sweep catches the rest: circles the caller merely
  // belonged to, plus the owner membership of any circle just transferred
  // (the heir keeps their own membership; the departing owner does not).
  // Also detach invites the caller created in surviving circles, since
  // created_by_profile_id would otherwise dangle.
  await db
    .delete(circleInvites)
    .where(eq(circleInvites.createdByProfileId, profileId));

  const deletedMemberships = await db
    .delete(circleMembers)
    .where(eq(circleMembers.profileId, profileId))
    .returning({ id: circleMembers.id });
  summary.circle_memberships = deletedMemberships.length;

  // --- LLM usage ledger (keyed by the JWT sub / careblazers_user_id) ---
  const deletedUsage = await db
    .delete(llmUsage)
    .where(eq(llmUsage.userId, careblazersUserId))
    .returning({ id: llmUsage.id });
  summary.llm_usage = deletedUsage.length;

  // --- The profile row itself (last) ----------------------------------
  const deletedProfiles = await db
    .delete(profiles)
    .where(eq(profiles.id, profileId))
    .returning({ id: profiles.id });
  summary.profiles = deletedProfiles.length;

  return summary;
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

    const [current] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.careblazersUserId, careblazersUserId));
    if (!current) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_body' }, 400);
    }
    if (!body || typeof body !== 'object') {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const patch = body as {
      display_name?: unknown;
      username?: unknown;
      avatar_url?: unknown;
    };
    const updates: {
      displayName?: string;
      username?: string;
      avatarUrl?: string;
    } = {};

    if (patch.username !== undefined) {
      if (
        typeof patch.username !== 'string' ||
        !USERNAME_PATTERN.test(patch.username)
      ) {
        return c.json({ error: 'invalid_username' }, 400);
      }
      if (containsProfanity(patch.username)) {
        return c.json({ error: 'profanity_blocked' }, 400);
      }
      const handle = patch.username.toLowerCase();
      const [taken] = await db
        .select({ id: profiles.id })
        .from(profiles)
        .where(
          and(
            eq(profiles.username, handle),
            ne(profiles.careblazersUserId, careblazersUserId),
          ),
        );
      if (taken) {
        return c.json({ error: 'username_taken' }, 409);
      }
      updates.username = handle;
      // Username is the canonical public identity: when one is being set
      // and the profile still carries the auto-generated default
      // display_name, mirror the username into display_name so every
      // surface that renders display_name shows the chosen handle. A
      // display_name the caregiver explicitly customized (one that does
      // NOT match the default `Caregiver_<hex>` shape) is preserved. An
      // explicit display_name in this same PATCH still wins (applied below).
      if (isDefaultDisplayName(current.displayName)) {
        updates.displayName = handle;
      }
    }

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

  // Full account deletion (privacy Principle 1 + Apple 5.1.1(v)): tears
  // down EVERYTHING tied to the caller and returns a summary of what was
  // removed. It is a hard delete, not a soft flag — nothing about this
  // account survives.
  //
  // Cascade, in dependency order (see `deleteAccount` below):
  //   - forum content: posts, comments, votes, reports the caller authored
  //   - care circles the caller SOLELY owns → the circle, its patient +
  //     care_docs + members + invites, AND the R2 document blobs under
  //     `documents/<circleId>/`
  //   - SHARED circles the caller owns (other members remain) → ownership
  //     transfers to another member; the shared care data is preserved
  //   - the caller's remaining circle memberships
  //   - the caller's LLM usage ledger rows
  //   - the profile row itself
  //
  // We do NOT lean on SQLite FK cascades: D1 does not enable
  // `PRAGMA foreign_keys` per connection, so the schema's `onDelete`
  // clauses are inert at runtime. Every row is removed explicitly. (This
  // is also why deleting the profile first would be a data-loss bug: the
  // circles.owner_profile_id FK would NOT cascade, orphaning shared care
  // data — hence the ownership transfer below.)
  router.delete('/me', async (c) => {
    const careblazersUserId = c.get('userId');
    const db = drizzle(c.env.FORUM_DB);

    const [profile] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.careblazersUserId, careblazersUserId));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    const summary = await deleteAccount(
      db,
      c.env.DOC_BLOBS,
      profile.id,
      careblazersUserId,
    );
    return c.json({ deleted: summary }, 200);
  });

  router.get('/username-available', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const handle = c.req.query('u') ?? '';

    const valid = USERNAME_PATTERN.test(handle) && !containsProfanity(handle);
    if (!valid) {
      return c.json({ valid: false, available: false }, 200);
    }

    const [existing] = await db
      .select({ id: profiles.id })
      .from(profiles)
      .where(eq(profiles.username, handle));
    return c.json({ valid: true, available: !existing }, 200);
  });

  router.get('/by-username/:username', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const handle = c.req.param('username').toLowerCase();

    const [profile] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.username, handle));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }
    return c.json(
      {
        id: profile.id,
        username: profile.username,
        display_name: profile.displayName,
        avatar_url: profile.avatarUrl,
      },
      200,
    );
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

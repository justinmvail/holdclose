import { and, eq, inArray, isNull } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono } from 'hono';

import {
  circleInvites,
  circleMembers,
  circles,
  patients,
  profiles,
  type Circle,
  type Patient,
  type Profile,
} from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';
import { nextRev } from './sync';

export type CirclesBindings = AuthBindings & {
  FORUM_DB: D1Database;
};

export type CirclesVariables = AuthVariables;

const NAME_MIN = 1;
const NAME_MAX = 60;
// 48h (was 7 days): an invite is a key to the loved one's medical data —
// it should not outlive the "text it to your sister, she taps it tonight"
// window by much. Invites are also single-use (consumed on join).
const INVITE_TTL_MS = 48 * 60 * 60 * 1000;

type Db = ReturnType<typeof drizzle>;

async function loadProfileByUserId(
  db: Db,
  careblazersUserId: string,
): Promise<Profile | undefined> {
  const [row] = await db
    .select()
    .from(profiles)
    .where(eq(profiles.careblazersUserId, careblazersUserId));
  return row;
}

type MemberRow = {
  profile_id: string;
  username: string | null;
  display_name: string;
  role: string;
};

async function loadMembers(db: Db, circleId: string): Promise<MemberRow[]> {
  const rows = await db
    .select({
      profileId: circleMembers.profileId,
      role: circleMembers.role,
      username: profiles.username,
      displayName: profiles.displayName,
    })
    .from(circleMembers)
    .innerJoin(profiles, eq(circleMembers.profileId, profiles.id))
    .where(eq(circleMembers.circleId, circleId));
  return rows.map((r) => ({
    profile_id: r.profileId,
    username: r.username ?? null,
    display_name: r.displayName,
    role: r.role,
  }));
}

function patientResponse(p: Patient) {
  return {
    payload: p.payload,
    client_updated_at: p.clientUpdatedAt,
    rev: p.rev,
    deleted: p.deleted,
  };
}

async function loadPatient(
  db: Db,
  circleId: string,
): Promise<Patient | undefined> {
  const [row] = await db
    .select()
    .from(patients)
    .where(eq(patients.circleId, circleId));
  return row;
}

function circleResponse(
  circle: Circle,
  members: MemberRow[],
  patient?: Patient,
) {
  return {
    id: circle.id,
    name: circle.name,
    owner_profile_id: circle.ownerProfileId,
    created_at: circle.createdAt.toISOString(),
    members,
    patient: patient ? patientResponse(patient) : null,
  };
}

export const circlesRouter = () => {
  const router = new Hono<{
    Bindings: CirclesBindings;
    Variables: CirclesVariables;
  }>();

  router.post('/', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    let raw: unknown;
    try {
      raw = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_body' }, 400);
    }
    if (!raw || typeof raw !== 'object') {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const { name, patient: patientInput } = raw as {
      name?: unknown;
      patient?: unknown;
    };
    if (
      typeof name !== 'string' ||
      name.length < NAME_MIN ||
      name.length > NAME_MAX
    ) {
      return c.json({ error: 'invalid_name' }, 400);
    }

    // Optional initial loved-one profile. Defaults to an empty payload.
    let patientPayload = '{}';
    let patientClientUpdatedAt = Date.now();
    if (patientInput !== undefined) {
      if (!patientInput || typeof patientInput !== 'object') {
        return c.json({ error: 'invalid_body' }, 400);
      }
      const p = patientInput as Record<string, unknown>;
      if (
        typeof p.payload !== 'string' ||
        typeof p.client_updated_at !== 'number' ||
        // JSON `1e999` parses to Infinity — typeof 'number' alone lets it
        // through to a D1 constraint error (the onError test leans on
        // that); reject it as the client mistake it is.
        !Number.isFinite(p.client_updated_at)
      ) {
        return c.json({ error: 'invalid_body' }, 400);
      }
      patientPayload = p.payload;
      patientClientUpdatedAt = p.client_updated_at;
    }

    const [circle] = await db
      .insert(circles)
      .values({ name, ownerProfileId: profile.id })
      .returning();
    await db
      .insert(circleMembers)
      .values({ circleId: circle.id, profileId: profile.id, role: 'owner' });

    // Create the circle's single loved one, assigning rev from the
    // circle's syncCounter (the per-circle monotonic delta cursor).
    const rev = await nextRev(db, circle.id);
    const [patient] = await db
      .insert(patients)
      .values({
        circleId: circle.id,
        payload: patientPayload,
        clientUpdatedAt: patientClientUpdatedAt,
        rev,
      })
      .returning();

    const members = await loadMembers(db, circle.id);
    return c.json(circleResponse(circle, members, patient), 201);
  });

  router.get('/', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    const memberships = await db
      .select({ circleId: circleMembers.circleId })
      .from(circleMembers)
      .where(eq(circleMembers.profileId, profile.id));
    const circleIds = memberships.map((m) => m.circleId);
    if (circleIds.length === 0) {
      return c.json({ circles: [] }, 200);
    }

    const rows = await db
      .select()
      .from(circles)
      .where(inArray(circles.id, circleIds));

    const payload = await Promise.all(
      rows.map(async (circle) =>
        circleResponse(
          circle,
          await loadMembers(db, circle.id),
          await loadPatient(db, circle.id),
        ),
      ),
    );
    return c.json({ circles: payload }, 200);
  });

  router.post('/:id/invites', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    const circleId = c.req.param('id');
    const [membership] = await db
      .select()
      .from(circleMembers)
      .where(
        and(
          eq(circleMembers.circleId, circleId),
          eq(circleMembers.profileId, profile.id),
        ),
      );
    if (!membership) {
      return c.json({ error: 'forbidden' }, 403);
    }

    const now = new Date();
    const expiresAt = new Date(now.getTime() + INVITE_TTL_MS);
    const [invite] = await db
      .insert(circleInvites)
      .values({
        token: crypto.randomUUID(),
        circleId,
        createdByProfileId: profile.id,
        expiresAt,
      })
      .returning();

    return c.json(
      {
        token: invite.token,
        circle_id: invite.circleId,
        expires_at: invite.expiresAt.toISOString(),
      },
      201,
    );
  });

  router.post('/join', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return c.json({ error: 'profile_not_found' }, 404);
    }

    let raw: unknown;
    try {
      raw = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_body' }, 400);
    }
    if (!raw || typeof raw !== 'object') {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const { token } = raw as { token?: unknown };
    if (typeof token !== 'string' || token.length === 0) {
      return c.json({ error: 'invalid_body' }, 400);
    }

    const [invite] = await db
      .select()
      .from(circleInvites)
      .where(eq(circleInvites.token, token));
    if (!invite) {
      return c.json({ error: 'invite_not_found' }, 404);
    }
    if (invite.revoked || invite.expiresAt.getTime() <= Date.now()) {
      return c.json({ error: 'invite_expired' }, 410);
    }

    const [existing] = await db
      .select()
      .from(circleMembers)
      .where(
        and(
          eq(circleMembers.circleId, invite.circleId),
          eq(circleMembers.profileId, profile.id),
        ),
      );
    if (!existing) {
      // Single-use: CLAIM the invite atomically before admitting the new
      // member. The conditional `used_at IS NULL` update means two racing
      // redeemers can't both get in — exactly one UPDATE wins; the loser
      // sees zero rows and gets `invite_used`. Existing members short-
      // circuit above without consuming (re-tapping an old link after
      // you've already joined is benign and idempotent).
      const claimed = await db
        .update(circleInvites)
        .set({ usedAt: new Date(), usedByProfileId: profile.id })
        .where(
          and(
            eq(circleInvites.token, token),
            isNull(circleInvites.usedAt),
          ),
        )
        .returning({ token: circleInvites.token });
      if (claimed.length === 0) {
        return c.json({ error: 'invite_used' }, 410);
      }
      await db.insert(circleMembers).values({
        circleId: invite.circleId,
        profileId: profile.id,
        role: 'member',
      });
    }

    const [circle] = await db
      .select()
      .from(circles)
      .where(eq(circles.id, invite.circleId));
    const members = await loadMembers(db, invite.circleId);
    const patient = await loadPatient(db, invite.circleId);
    return c.json(circleResponse(circle, members, patient), 200);
  });

  return router;
};

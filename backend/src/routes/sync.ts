import { and, eq, gt, sql } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { Hono, type Context } from 'hono';

import {
  careDocs,
  circleMembers,
  circles,
  patients,
  profiles,
  type CareDoc,
  type Patient,
  type Profile,
} from '../db/schema';
import type { AuthBindings, AuthVariables } from '../middleware/auth';

export type SyncBindings = AuthBindings & {
  FORUM_DB: D1Database;
};

export type SyncVariables = AuthVariables;

type Db = ReturnType<typeof drizzle>;

const MAX_PUSH_DOCS = 500;

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

/**
 * Allocate the next per-circle monotonic revision. Reads + increments the
 * circle's syncCounter and returns the new value. Callers assign this to a
 * row's `rev`, making rev strictly increasing per circle and skew-proof
 * (unlike wall-clock). The UPDATE ... RETURNING is a single atomic SQL
 * statement, so concurrent allocations cannot collide on a value.
 */
export async function nextRev(db: Db, circleId: string): Promise<number> {
  const [row] = await db
    .update(circles)
    .set({ syncCounter: sql`${circles.syncCounter} + 1` })
    .where(eq(circles.id, circleId))
    .returning({ syncCounter: circles.syncCounter });
  return row.syncCounter;
}

function patientResponse(p: Patient) {
  return {
    payload: p.payload,
    client_updated_at: p.clientUpdatedAt,
    rev: p.rev,
    deleted: p.deleted,
  };
}

function careDocResponse(d: CareDoc) {
  return {
    id: d.id,
    collection: d.collection,
    payload: d.payload,
    client_updated_at: d.clientUpdatedAt,
    rev: d.rev,
    deleted: d.deleted,
  };
}

type IncomingDoc = {
  id: string;
  collection: string;
  payload: string;
  client_updated_at: number;
  deleted?: boolean;
};

type IncomingPatient = {
  payload: string;
  client_updated_at: number;
  deleted?: boolean;
};

function parsePatient(raw: unknown): IncomingPatient | null | undefined {
  if (raw === undefined) return undefined;
  if (!raw || typeof raw !== 'object') return null;
  const p = raw as Record<string, unknown>;
  if (
    typeof p.payload !== 'string' ||
    typeof p.client_updated_at !== 'number' ||
    (p.deleted !== undefined && typeof p.deleted !== 'boolean')
  ) {
    return null;
  }
  return {
    payload: p.payload,
    client_updated_at: p.client_updated_at,
    deleted: p.deleted as boolean | undefined,
  };
}

function parseDoc(raw: unknown): IncomingDoc | null {
  if (!raw || typeof raw !== 'object') return null;
  const d = raw as Record<string, unknown>;
  if (
    typeof d.id !== 'string' ||
    d.id.length === 0 ||
    typeof d.collection !== 'string' ||
    d.collection.length === 0 ||
    typeof d.payload !== 'string' ||
    typeof d.client_updated_at !== 'number' ||
    (d.deleted !== undefined && typeof d.deleted !== 'boolean')
  ) {
    return null;
  }
  return {
    id: d.id,
    collection: d.collection,
    payload: d.payload,
    client_updated_at: d.client_updated_at,
    deleted: d.deleted as boolean | undefined,
  };
}

export const syncRouter = () => {
  const router = new Hono<{
    Bindings: SyncBindings;
    Variables: SyncVariables;
  }>();

  // Resolve caller profile + circle membership. Returns the loaded circle
  // sync state on success, or an error Response to short-circuit.
  async function authorize(
    c: Context<{ Bindings: SyncBindings; Variables: SyncVariables }>,
    db: Db,
    circleId: string,
  ): Promise<
    | { ok: true; profile: Profile; syncCounter: number }
    | { ok: false; res: Response }
  > {
    const profile = await loadProfileByUserId(db, c.get('userId'));
    if (!profile) {
      return { ok: false, res: c.json({ error: 'profile_not_found' }, 404) };
    }
    const [circle] = await db
      .select({ id: circles.id, syncCounter: circles.syncCounter })
      .from(circles)
      .where(eq(circles.id, circleId));
    if (!circle) {
      return { ok: false, res: c.json({ error: 'not_found' }, 404) };
    }
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
      return { ok: false, res: c.json({ error: 'forbidden' }, 403) };
    }
    return { ok: true, profile, syncCounter: circle.syncCounter };
  }

  // Delta pull. since defaults to 0 (full pull).
  router.get('/:circleId', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const circleId = c.req.param('circleId');
    const authd = await authorize(c, db, circleId);
    if (!authd.ok) return authd.res;

    const sinceParam = c.req.query('since');
    const since = sinceParam ? Number.parseInt(sinceParam, 10) : 0;
    const safeSince = Number.isFinite(since) && since >= 0 ? since : 0;

    const [patientRow] = await db
      .select()
      .from(patients)
      .where(eq(patients.circleId, circleId));
    const patient =
      patientRow && patientRow.rev > safeSince
        ? patientResponse(patientRow)
        : null;

    const docRows = await db
      .select()
      .from(careDocs)
      .where(
        and(eq(careDocs.circleId, circleId), gt(careDocs.rev, safeSince)),
      )
      .orderBy(careDocs.rev);

    return c.json(
      {
        cursor: authd.syncCounter,
        patient,
        docs: docRows.map(careDocResponse),
      },
      200,
    );
  });

  // Push (last-write-wins by client_updated_at).
  router.post('/:circleId', async (c) => {
    const db = drizzle(c.env.FORUM_DB);
    const circleId = c.req.param('circleId');
    const authd = await authorize(c, db, circleId);
    if (!authd.ok) return authd.res;

    let raw: unknown;
    try {
      raw = await c.req.json();
    } catch {
      return c.json({ error: 'invalid_body' }, 400);
    }
    if (!raw || typeof raw !== 'object') {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const body = raw as Record<string, unknown>;

    const incomingPatient = parsePatient(body.patient);
    if (incomingPatient === null) {
      return c.json({ error: 'invalid_body' }, 400);
    }

    const docsRaw = body.docs;
    if (docsRaw !== undefined && !Array.isArray(docsRaw)) {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const docsArr = (docsRaw ?? []) as unknown[];
    if (docsArr.length > MAX_PUSH_DOCS) {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const parsedDocs: IncomingDoc[] = [];
    for (const d of docsArr) {
      const parsed = parseDoc(d);
      if (!parsed) {
        return c.json({ error: 'invalid_body' }, 400);
      }
      parsedDocs.push(parsed);
    }

    // Patient: LWW upsert.
    let authoritativePatient: Patient | undefined;
    {
      const [stored] = await db
        .select()
        .from(patients)
        .where(eq(patients.circleId, circleId));
      authoritativePatient = stored;
      if (incomingPatient) {
        if (!stored || incomingPatient.client_updated_at >= stored.clientUpdatedAt) {
          const rev = await nextRev(db, circleId);
          if (stored) {
            const [updated] = await db
              .update(patients)
              .set({
                payload: incomingPatient.payload,
                clientUpdatedAt: incomingPatient.client_updated_at,
                deleted: incomingPatient.deleted ?? false,
                rev,
              })
              .where(eq(patients.circleId, circleId))
              .returning();
            authoritativePatient = updated;
          } else {
            const [inserted] = await db
              .insert(patients)
              .values({
                circleId,
                payload: incomingPatient.payload,
                clientUpdatedAt: incomingPatient.client_updated_at,
                deleted: incomingPatient.deleted ?? false,
                rev,
              })
              .returning();
            authoritativePatient = inserted;
          }
        }
      }
    }

    // Docs: LWW upsert per id.
    const applied: { id: string; rev: number; accepted: boolean }[] = [];
    for (const doc of parsedDocs) {
      const [stored] = await db
        .select()
        .from(careDocs)
        .where(eq(careDocs.id, doc.id));
      const accept =
        !stored || doc.client_updated_at >= stored.clientUpdatedAt;
      if (accept) {
        const rev = await nextRev(db, circleId);
        if (stored) {
          await db
            .update(careDocs)
            .set({
              collection: doc.collection,
              payload: doc.payload,
              clientUpdatedAt: doc.client_updated_at,
              deleted: doc.deleted ?? false,
              rev,
            })
            .where(eq(careDocs.id, doc.id));
        } else {
          await db.insert(careDocs).values({
            id: doc.id,
            circleId,
            collection: doc.collection,
            payload: doc.payload,
            clientUpdatedAt: doc.client_updated_at,
            deleted: doc.deleted ?? false,
            rev,
          });
        }
        applied.push({ id: doc.id, rev, accepted: true });
      } else {
        applied.push({ id: doc.id, rev: stored.rev, accepted: false });
      }
    }

    // Re-read the circle counter for the authoritative cursor.
    const [circleRow] = await db
      .select({ syncCounter: circles.syncCounter })
      .from(circles)
      .where(eq(circles.id, circleId));

    return c.json(
      {
        cursor: circleRow.syncCounter,
        patient: authoritativePatient
          ? patientResponse(authoritativePatient)
          : null,
        applied,
      },
      200,
    );
  });

  return router;
};

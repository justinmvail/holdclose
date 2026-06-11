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

/**
 * Per-document payload byte ceiling (also applied to the patient payload).
 * Care docs are small JSON blobs — a journal entry, a med schedule — so a
 * quarter megabyte is generous. Without a cap a hostile client could park
 * multi-MB strings in D1 rows that every circle member then re-downloads
 * on each delta pull. An oversized payload rejects the WHOLE push (the
 * client treats 4xx as retry-later; silently dropping single docs would
 * strand them in the outbox as phantom "synced" data).
 */
const MAX_DOC_PAYLOAD_BYTES = 256 * 1024;

/**
 * The collections the client actually pushes — mirror of SyncCollections
 * in lib/services/sync_service.dart. An unknown collection is a client
 * bug or a probe; reject it instead of storing arbitrary namespaces.
 * 'patient' travels via the dedicated `patient` field rather than `docs`,
 * but stays in the list for forward-compat.
 */
const ALLOWED_COLLECTIONS = new Set([
  'patient',
  'medication',
  'dose_window',
  'medication_window_entry',
  'dose_log',
  'journal_entries',
  'chat_conversations',
  'chat_messages',
  'appointments',
  'providers',
  'health_log_entries',
  'care_plan_routines',
  'care_events',
  'care_tasks',
  'care_shifts',
  'expenses',
  'caregivers',
  'care_circle_memberships',
  'emergency_cards',
  'power_of_attorney_docs',
  'identification_docs',
]);

// Payloads are JSON strings; the cap is on UTF-8 bytes (what D1 stores),
// not UTF-16 code units, so multibyte text can't slip past it.
function utf8ByteLength(s: string): number {
  return new TextEncoder().encode(s).byteLength;
}

/**
 * LWW trusts the client's `client_updated_at`, so an absurd future
 * timestamp (buggy or hostile clock) would otherwise win every future
 * conflict FOREVER — permanently locking other members out of editing
 * that row. Cap accepted values at server-now plus a generous skew
 * allowance; the write is still accepted (no data loss), it just can't
 * project itself into the far future.
 */
const MAX_CLIENT_CLOCK_SKEW_MS = 24 * 60 * 60 * 1000;

function clampClientUpdatedAt(claimed: number, nowMs: number): number {
  const max = nowMs + MAX_CLIENT_CLOCK_SKEW_MS;
  return claimed > max ? max : claimed;
}

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
    !Number.isFinite(p.client_updated_at) ||
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
    !Number.isFinite(d.client_updated_at) ||
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
    if (
      incomingPatient &&
      utf8ByteLength(incomingPatient.payload) > MAX_DOC_PAYLOAD_BYTES
    ) {
      return c.json({ error: 'payload_too_large' }, 400);
    }

    const docsRaw = body.docs;
    if (docsRaw !== undefined && !Array.isArray(docsRaw)) {
      return c.json({ error: 'invalid_body' }, 400);
    }
    const docsArr = (docsRaw ?? []) as unknown[];
    if (docsArr.length > MAX_PUSH_DOCS) {
      return c.json({ error: 'invalid_body' }, 400);
    }
    // All docs are validated BEFORE any write below, so a bad batch is
    // all-or-nothing — no doc from a rejected push is partially applied.
    const parsedDocs: IncomingDoc[] = [];
    for (const d of docsArr) {
      const parsed = parseDoc(d);
      if (!parsed) {
        return c.json({ error: 'invalid_body' }, 400);
      }
      if (!ALLOWED_COLLECTIONS.has(parsed.collection)) {
        return c.json({ error: 'invalid_body' }, 400);
      }
      if (utf8ByteLength(parsed.payload) > MAX_DOC_PAYLOAD_BYTES) {
        return c.json({ error: 'payload_too_large' }, 400);
      }
      parsedDocs.push(parsed);
    }

    const nowMs = Date.now();

    // Patient: LWW upsert (clock-clamped — see MAX_CLIENT_CLOCK_SKEW_MS).
    let authoritativePatient: Patient | undefined;
    {
      const [stored] = await db
        .select()
        .from(patients)
        .where(eq(patients.circleId, circleId));
      authoritativePatient = stored;
      if (incomingPatient) {
        const effectiveUpdatedAt = clampClientUpdatedAt(
          incomingPatient.client_updated_at,
          nowMs,
        );
        if (!stored || effectiveUpdatedAt >= stored.clientUpdatedAt) {
          const rev = await nextRev(db, circleId);
          if (stored) {
            const [updated] = await db
              .update(patients)
              .set({
                payload: incomingPatient.payload,
                clientUpdatedAt: effectiveUpdatedAt,
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
                clientUpdatedAt: effectiveUpdatedAt,
                deleted: incomingPatient.deleted ?? false,
                rev,
              })
              .returning();
            authoritativePatient = inserted;
          }
        }
      }
    }

    // Docs: LWW upsert per id, ALWAYS scoped to the authorized circle.
    // Doc ids are client-minted and only unique per circle (composite
    // PK), so an unscoped lookup here would let one circle's push read
    // or overwrite another circle's row that happens to share an id.
    const applied: { id: string; rev: number; accepted: boolean }[] = [];
    for (const doc of parsedDocs) {
      const [stored] = await db
        .select()
        .from(careDocs)
        .where(
          and(eq(careDocs.id, doc.id), eq(careDocs.circleId, circleId)),
        );
      const effectiveUpdatedAt = clampClientUpdatedAt(
        doc.client_updated_at,
        nowMs,
      );
      const accept =
        !stored || effectiveUpdatedAt >= stored.clientUpdatedAt;
      if (accept) {
        const rev = await nextRev(db, circleId);
        if (stored) {
          await db
            .update(careDocs)
            .set({
              collection: doc.collection,
              payload: doc.payload,
              clientUpdatedAt: effectiveUpdatedAt,
              deleted: doc.deleted ?? false,
              rev,
            })
            .where(
              and(eq(careDocs.id, doc.id), eq(careDocs.circleId, circleId)),
            );
        } else {
          await db.insert(careDocs).values({
            id: doc.id,
            circleId,
            collection: doc.collection,
            payload: doc.payload,
            clientUpdatedAt: effectiveUpdatedAt,
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

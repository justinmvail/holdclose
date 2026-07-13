import { SELF, env } from 'cloudflare:test';
import { drizzle } from 'drizzle-orm/d1';
import { eq } from 'drizzle-orm';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

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
} from '../src/db/schema';

const SECRET = env.FORUM_JWT_SECRET;
const ORIGIN = 'https://forum.holdclose.local';

const nowSec = () => Math.floor(Date.now() / 1000);

async function mintToken(sub: string) {
  const iat = nowSec();
  return sign({ sub, iat, exp: iat + 3600 }, SECRET, 'HS256');
}

async function authedFetch(path: string, init: RequestInit & { sub: string }) {
  const token = await mintToken(init.sub);
  return SELF.fetch(`${ORIGIN}${path}`, {
    ...init,
    headers: {
      ...(init.headers ?? {}),
      Authorization: `Bearer ${token}`,
    },
  });
}

async function clearTables() {
  await env.FORUM_DB.batch([
    env.FORUM_DB.prepare('DELETE FROM llm_usage'),
    env.FORUM_DB.prepare('DELETE FROM votes'),
    env.FORUM_DB.prepare('DELETE FROM reports'),
    env.FORUM_DB.prepare('DELETE FROM comments'),
    env.FORUM_DB.prepare('DELETE FROM posts'),
    env.FORUM_DB.prepare('DELETE FROM care_docs'),
    env.FORUM_DB.prepare('DELETE FROM patients'),
    env.FORUM_DB.prepare('DELETE FROM circle_invites'),
    env.FORUM_DB.prepare('DELETE FROM circle_members'),
    env.FORUM_DB.prepare('DELETE FROM circles'),
    env.FORUM_DB.prepare('DELETE FROM profiles'),
  ]);
}

// Drain the R2 document namespace so no blobs leak between tests.
async function clearBlobs() {
  let cursor: string | undefined;
  do {
    const listed = await env.DOC_BLOBS.list({ cursor });
    const keys = listed.objects.map((o) => o.key);
    if (keys.length > 0) await env.DOC_BLOBS.delete(keys);
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
}

async function bootstrap(sub: string) {
  return (await (
    await authedFetch('/api/v1/profiles/bootstrap', { method: 'POST', sub })
  ).json()) as { id: string };
}

async function createCircle(sub: string, name = 'Care Team') {
  const res = await authedFetch('/api/v1/circles', {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name }),
  });
  return (await res.json()) as { id: string };
}

async function inviteToken(sub: string, circleId: string) {
  const res = await authedFetch(`/api/v1/circles/${circleId}/invites`, {
    method: 'POST',
    sub,
  });
  return ((await res.json()) as { token: string }).token;
}

async function join(sub: string, token: string) {
  return authedFetch('/api/v1/circles/join', {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token }),
  });
}

async function pushDoc(
  sub: string,
  circleId: string,
  id: string,
  collection: string,
) {
  return authedFetch(`/api/v1/sync/${circleId}`, {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      docs: [
        { id, collection, payload: '{"x":1}', client_updated_at: 1000 },
      ],
    }),
  });
}

async function uploadBlob(sub: string, circleId: string, key: string) {
  return authedFetch(`/api/v1/documents/blob/${circleId}/${key}`, {
    method: 'PUT',
    sub,
    headers: { 'Content-Type': 'image/jpeg' },
    body: new Uint8Array([1, 2, 3, 4]),
  });
}

async function createPost(sub: string) {
  const res = await authedFetch('/api/v1/posts', {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: 'Hello there', body: 'A first post body.' }),
  });
  return (await res.json()) as { id: string };
}

async function createComment(sub: string, postId: string) {
  const res = await authedFetch(`/api/v1/posts/${postId}/comments`, {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ body: 'A comment body.' }),
  });
  return (await res.json()) as { id: string };
}

async function votePost(sub: string, postId: string, value: number) {
  return authedFetch('/api/v1/votes', {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ target_kind: 'post', target_id: postId, value }),
  });
}

async function reportPost(sub: string, postId: string) {
  return authedFetch('/api/v1/reports', {
    method: 'POST',
    sub,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      target_kind: 'post',
      target_id: postId,
      reason: 'spam',
    }),
  });
}

// llm_usage is populated by the /chat streaming handler, which needs a live
// inference host. Seed a row directly (keyed by the JWT sub, exactly like
// chat.ts does) so the deletion cascade for that table is exercised.
async function seedUsage(userId: string) {
  const db = drizzle(env.FORUM_DB);
  await db.insert(llmUsage).values({
    userId,
    model: 'gpt-oss-120b',
    feature: 'chat',
    promptTokens: 10,
    completionTokens: 5,
    costMicros: 42,
  });
}

beforeEach(async () => {
  await clearTables();
  await clearBlobs();
});

describe('DELETE /api/v1/profiles/me', () => {
  it('requires authentication', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/me`, {
      method: 'DELETE',
    });
    expect(res.status).toBe(401);
  });

  it('returns 404 when the caller has no profile', async () => {
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'DELETE',
      sub: 'cb-del-noprofile',
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'profile_not_found' });
  });

  it('cascades a full account deletion and reports what was removed', async () => {
    const db = drizzle(env.FORUM_DB);

    // --- The account under test: forum content + a solely-owned circle
    // with a patient, a synced care doc, and an R2 document blob. ---------
    const me = await bootstrap('cb-del-me');
    const soloCircle = await createCircle('cb-del-me', 'Mom');
    await pushDoc('cb-del-me', soloCircle.id, 'med-1', 'medication');
    const blobPut = await uploadBlob('cb-del-me', soloCircle.id, 'idcard.jpg');
    expect(blobPut.status).toBe(200);

    const myPost = await createPost('cb-del-me');
    await createComment('cb-del-me', myPost.id);
    await seedUsage('cb-del-me');

    // --- A bystander whose data must remain completely untouched. --------
    const other = await bootstrap('cb-del-other');
    const otherCircle = await createCircle('cb-del-other', 'Dad');
    await pushDoc('cb-del-other', otherCircle.id, 'med-o', 'medication');
    const otherBlob = await uploadBlob(
      'cb-del-other',
      otherCircle.id,
      'card-o.jpg',
    );
    expect(otherBlob.status).toBe(200);
    const otherPost = await createPost('cb-del-other');
    await createComment('cb-del-other', otherPost.id);
    await seedUsage('cb-del-other');

    // Cross-actor rows: the bystander votes on + reports my post; I vote on
    // + report the bystander's post. My rows must go; theirs must stay.
    await votePost('cb-del-other', myPost.id, 1);
    await reportPost('cb-del-other', myPost.id);
    await votePost('cb-del-me', otherPost.id, 1);
    await reportPost('cb-del-me', otherPost.id);

    // --- Delete the account. --------------------------------------------
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'DELETE',
      sub: 'cb-del-me',
    });
    expect(res.status).toBe(200);
    const { deleted } = (await res.json()) as {
      deleted: Record<string, number>;
    };
    expect(deleted).toMatchObject({
      profiles: 1,
      posts: 1,
      comments: 1,
      votes: 1,
      reports: 1,
      circles_owned: 1,
      circles_transferred: 0,
      patients: 1,
      care_docs: 1,
      document_blobs: 1,
      llm_usage: 1,
      // My only membership was in the solo circle, so it was removed as
      // part of that circle's teardown — the final membership sweep (which
      // this counter reports) finds nothing left.
      circle_memberships: 0,
    });

    // --- Nothing of mine survives. --------------------------------------
    const [profGone] = await db
      .select()
      .from(profiles)
      .where(eq(profiles.id, me.id));
    expect(profGone).toBeUndefined();

    expect(
      await db.select().from(posts).where(eq(posts.authorId, me.id)),
    ).toHaveLength(0);
    expect(
      await db.select().from(comments).where(eq(comments.authorId, me.id)),
    ).toHaveLength(0);
    expect(
      await db.select().from(votes).where(eq(votes.voterId, me.id)),
    ).toHaveLength(0);
    expect(
      await db.select().from(reports).where(eq(reports.reporterId, me.id)),
    ).toHaveLength(0);
    expect(
      await db.select().from(circles).where(eq(circles.id, soloCircle.id)),
    ).toHaveLength(0);
    expect(
      await db
        .select()
        .from(patients)
        .where(eq(patients.circleId, soloCircle.id)),
    ).toHaveLength(0);
    expect(
      await db
        .select()
        .from(careDocs)
        .where(eq(careDocs.circleId, soloCircle.id)),
    ).toHaveLength(0);
    expect(
      await db
        .select()
        .from(circleMembers)
        .where(eq(circleMembers.profileId, me.id)),
    ).toHaveLength(0);
    expect(
      await db.select().from(llmUsage).where(eq(llmUsage.userId, 'cb-del-me')),
    ).toHaveLength(0);

    // The R2 blob under my circle's namespace is gone.
    expect(
      await env.DOC_BLOBS.head(`documents/${soloCircle.id}/idcard.jpg`),
    ).toBeNull();

    // --- The bystander is fully intact — no IDOR / collateral damage. ---
    expect(
      await db.select().from(profiles).where(eq(profiles.id, other.id)),
    ).toHaveLength(1);
    expect(
      await db.select().from(posts).where(eq(posts.authorId, other.id)),
    ).toHaveLength(1);
    expect(
      await db.select().from(comments).where(eq(comments.authorId, other.id)),
    ).toHaveLength(1);
    // Their vote + report on MY post are standalone rows keyed by them —
    // those survive the target post's removal (no cascade wipes them).
    expect(
      await db.select().from(votes).where(eq(votes.voterId, other.id)),
    ).toHaveLength(1);
    expect(
      await db.select().from(reports).where(eq(reports.reporterId, other.id)),
    ).toHaveLength(1);
    expect(
      await db.select().from(circles).where(eq(circles.id, otherCircle.id)),
    ).toHaveLength(1);
    expect(
      await db
        .select()
        .from(careDocs)
        .where(eq(careDocs.circleId, otherCircle.id)),
    ).toHaveLength(1);
    expect(
      await db
        .select()
        .from(llmUsage)
        .where(eq(llmUsage.userId, 'cb-del-other')),
    ).toHaveLength(1);
    // The bystander's blob is untouched.
    expect(
      await env.DOC_BLOBS.head(`documents/${otherCircle.id}/card-o.jpg`),
    ).not.toBeNull();
  });

  it('transfers a shared circle to a remaining member instead of destroying it', async () => {
    const db = drizzle(env.FORUM_DB);

    const owner = await bootstrap('cb-del-owner');
    const shared = await createCircle('cb-del-owner', 'Grandma');
    await pushDoc('cb-del-owner', shared.id, 'med-s', 'medication');
    await uploadBlob('cb-del-owner', shared.id, 'shared.jpg');

    // A second caregiver joins the shared circle.
    const heir = await bootstrap('cb-del-heir');
    const token = await inviteToken('cb-del-owner', shared.id);
    expect((await join('cb-del-heir', token)).status).toBe(200);

    // The owner deletes their account.
    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'DELETE',
      sub: 'cb-del-owner',
    });
    expect(res.status).toBe(200);
    const { deleted } = (await res.json()) as {
      deleted: Record<string, number>;
    };
    expect(deleted.circles_transferred).toBe(1);
    expect(deleted.circles_owned).toBe(0);
    expect(deleted.care_docs).toBe(0); // shared data preserved
    expect(deleted.patients).toBe(0);
    expect(deleted.document_blobs).toBe(0);

    // The circle now belongs to the heir, who is now its owner-role member.
    const [circle] = await db
      .select()
      .from(circles)
      .where(eq(circles.id, shared.id));
    expect(circle).toBeDefined();
    expect(circle.ownerProfileId).toBe(heir.id);

    const [heirMembership] = await db
      .select()
      .from(circleMembers)
      .where(eq(circleMembers.profileId, heir.id));
    expect(heirMembership.role).toBe('owner');

    // The departed owner keeps no membership; the shared care doc + blob
    // survive.
    expect(
      await db
        .select()
        .from(circleMembers)
        .where(eq(circleMembers.profileId, owner.id)),
    ).toHaveLength(0);
    expect(
      await db.select().from(careDocs).where(eq(careDocs.circleId, shared.id)),
    ).toHaveLength(1);
    expect(
      await env.DOC_BLOBS.head(`documents/${shared.id}/shared.jpg`),
    ).not.toBeNull();
  });

  it('a member who JOINED VIA AN INVITE can delete their account', async () => {
    // Regression guard (live suite, 2026-07-13): this 500'd for every
    // caregiver who joined a circle by link — i.e. everyone in a care circle
    // except its creator. `circle_invites.used_by_profile_id` references
    // profiles(id) with NO `ON DELETE` action (its siblings cascade), and
    // deleteAccount only cleared invites the caller CREATED, never the one
    // they REDEEMED — so the final `DELETE FROM profiles` tripped the FK.
    //
    // The existing tests missed it because the only invite-redeeming case
    // above deletes the OWNER (whose profile nothing points at), never the
    // redeemer. Deleting the JOINER is the path real caregivers take.
    const db = drizzle(env.FORUM_DB);

    const owner = await bootstrap('cb-del-inv-owner');
    const circle = await createCircle('cb-del-inv-owner', 'Dad');
    const joiner = await bootstrap('cb-del-inv-joiner');
    const token = await inviteToken('cb-del-inv-owner', circle.id);
    expect((await join('cb-del-inv-joiner', token)).status).toBe(200);

    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'DELETE',
      sub: 'cb-del-inv-joiner',
    });
    expect(res.status).toBe(200);

    // The joiner is really gone...
    expect(
      await db.select().from(profiles).where(eq(profiles.id, joiner.id)),
    ).toHaveLength(0);
    expect(
      await db
        .select()
        .from(circleMembers)
        .where(eq(circleMembers.profileId, joiner.id)),
    ).toHaveLength(0);

    // ...the owner's circle is untouched...
    const [survivingCircle] = await db
      .select()
      .from(circles)
      .where(eq(circles.id, circle.id));
    expect(survivingCircle.ownerProfileId).toBe(owner.id);

    // ...and the invite row survives as the owner's audit trail, with the
    // redeemer pointer released but `used_at` still set — releasing it must
    // NOT re-open a consumed invite (single-use is claimed on used_at).
    const [invite] = await db
      .select()
      .from(circleInvites)
      .where(eq(circleInvites.token, token));
    expect(invite).toBeDefined();
    expect(invite.usedByProfileId).toBeNull();
    expect(invite.usedAt).not.toBeNull();

    // Prove it: a third caregiver still cannot redeem that consumed link.
    await bootstrap('cb-del-inv-replayer');
    const replay = await join('cb-del-inv-replayer', token);
    expect(replay.status).toBe(410);
    expect(await replay.json()).toEqual({ error: 'invite_used' });
  });
});

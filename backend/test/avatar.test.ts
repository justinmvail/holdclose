import { SELF, env } from 'cloudflare:test';
import { sign } from 'hono/jwt';
import { beforeEach, describe, expect, it } from 'vitest';

/// Profile avatars: upload (PUT /profiles/avatar) → public serve (GET /media/*)
/// → purge on account deletion.
///
/// This feature was DEAD end-to-end until 2026-07-13 (found while auditing
/// test coverage, not by a failing test — nothing covered it): the FORUM_MEDIA
/// bucket was bound but unused, there was no upload route at all, and
/// `R2_PUBLIC_URL` — the prefix `PATCH /me` requires an avatar_url to start
/// with — pointed at a placeholder domain that resolved nowhere. So an avatar
/// could neither be stored nor loaded.
///
/// The security-relevant properties pinned here:
///  * only raster image types are accepted — an SVG/HTML "avatar" would be an
///    ACTIVE DOCUMENT executing on our own origin, since we serve it back;
///  * the served response is `nosniff`, so a browser can't reinterpret it;
///  * `/media/*` refuses anything that isn't an avatar key (no traversal, no
///    reading other namespaces out of the bucket — the route is PUBLIC);
///  * deleting an account purges the caller's photo — it is served publicly,
///    so it must not outlive the account.
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

async function bootstrap(sub: string) {
  return (await (
    await authedFetch('/api/v1/profiles/bootstrap', { method: 'POST', sub })
  ).json()) as { id: string };
}

/** Upload raw image bytes as [sub]'s avatar. */
async function putAvatar(
  sub: string,
  body: BodyInit,
  contentType = 'image/png',
) {
  return authedFetch('/api/v1/profiles/avatar', {
    method: 'PUT',
    sub,
    headers: { 'Content-Type': contentType },
    body,
  });
}

/** A 1×1 PNG's bytes — small, but a genuine raster image. */
const PNG_BYTES = Uint8Array.from(
  atob(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  ),
  (ch) => ch.charCodeAt(0),
);

async function clearAll() {
  await env.FORUM_DB.batch([
    env.FORUM_DB.prepare('DELETE FROM comments'),
    env.FORUM_DB.prepare('DELETE FROM posts'),
    env.FORUM_DB.prepare('DELETE FROM profiles'),
  ]);
  let cursor: string | undefined;
  do {
    const listed = await env.FORUM_MEDIA.list({ cursor });
    const keys = listed.objects.map((o) => o.key);
    if (keys.length > 0) await env.FORUM_MEDIA.delete(keys);
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
}

beforeEach(clearAll);

describe('PUT /api/v1/profiles/avatar', () => {
  it('requires authentication', async () => {
    const res = await SELF.fetch(`${ORIGIN}/api/v1/profiles/avatar`, {
      method: 'PUT',
      headers: { 'Content-Type': 'image/png' },
      body: PNG_BYTES,
    });
    expect(res.status).toBe(401);
  });

  it('404s when the caller has no profile yet', async () => {
    const res = await putAvatar('cb-avatar-noprofile', PNG_BYTES);
    expect(res.status).toBe(404);
  });

  it('stores the image and returns a profile whose avatar_url resolves', async () => {
    const profile = await bootstrap('cb-avatar-happy');

    const res = await putAvatar('cb-avatar-happy', PNG_BYTES);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { avatar_url: string };

    // The minted URL must live on our media origin — the same prefix
    // PATCH /me enforces, so the two paths can't disagree.
    expect(body.avatar_url.startsWith(env.R2_PUBLIC_URL)).toBe(true);
    expect(body.avatar_url).toContain(`/avatars/${profile.id}/`);

    // ...and it must actually SERVE. Fetching the minted URL's path is the
    // whole point: before this feature existed, avatar_url pointed at a
    // domain that resolved nowhere.
    const key = body.avatar_url.slice(env.R2_PUBLIC_URL.length);
    const served = await SELF.fetch(`${ORIGIN}/media${key}`);
    expect(served.status).toBe(200);
    expect(served.headers.get('content-type')).toBe('image/png');
    expect(served.headers.get('x-content-type-options')).toBe('nosniff');
    expect(new Uint8Array(await served.arrayBuffer())).toEqual(PNG_BYTES);
  });

  it('is PUBLIC to read — the forum feed is read-anonymous, so faces must load without a session', async () => {
    await bootstrap('cb-avatar-public');
    const res = await putAvatar('cb-avatar-public', PNG_BYTES);
    const { avatar_url } = (await res.json()) as { avatar_url: string };
    const key = avatar_url.slice(env.R2_PUBLIC_URL.length);

    // No Authorization header at all.
    const served = await SELF.fetch(`${ORIGIN}/media${key}`);
    expect(served.status).toBe(200);
    // Drain the R2 stream: an unconsumed body keeps the object handle open and
    // miniflare's isolated-storage teardown then fails between tests.
    await served.arrayBuffer();
  });

  it('REJECTS active document types — an SVG avatar would execute on our origin', async () => {
    await bootstrap('cb-avatar-svg');
    for (const type of ['image/svg+xml', 'text/html', 'application/javascript']) {
      const res = await putAvatar(
        'cb-avatar-svg',
        '<svg onload="alert(1)"/>',
        type,
      );
      expect(res.status, type).toBe(415);
    }
  });

  it('rejects an empty body (400) and an oversized image (413)', async () => {
    await bootstrap('cb-avatar-size');

    const empty = await putAvatar('cb-avatar-size', new Uint8Array(0));
    expect(empty.status).toBe(400);

    const huge = await putAvatar(
      'cb-avatar-size',
      new Uint8Array(2 * 1024 * 1024 + 1),
    );
    expect(huge.status).toBe(413);
  });

  it('REPLACES the previous photo — one profile cannot accrete objects', async () => {
    const profile = await bootstrap('cb-avatar-replace');

    const first = await putAvatar('cb-avatar-replace', PNG_BYTES);
    const firstUrl = ((await first.json()) as { avatar_url: string }).avatar_url;

    const second = await putAvatar('cb-avatar-replace', PNG_BYTES);
    const secondUrl = ((await second.json()) as { avatar_url: string })
      .avatar_url;

    // A new upload mints a NEW key (so caches can't serve the stale face)...
    expect(secondUrl).not.toBe(firstUrl);
    // ...and exactly ONE object remains for this profile.
    const listed = await env.FORUM_MEDIA.list({
      prefix: `avatars/${profile.id}/`,
    });
    expect(listed.objects).toHaveLength(1);
    // The old URL is gone, not merely unreferenced.
    const stale = await SELF.fetch(
      `${ORIGIN}/media${firstUrl.slice(env.R2_PUBLIC_URL.length)}`,
    );
    expect(stale.status).toBe(404);
    await stale.arrayBuffer();
  });
});

describe('GET /media/* (public avatar serving)', () => {
  it('404s for a missing object', async () => {
    const res = await SELF.fetch(
      `${ORIGIN}/media/avatars/nobody/00000000-0000-0000-0000-000000000000.png`,
    );
    expect(res.status).toBe(404);
    await res.arrayBuffer();
  });

  it('refuses any key outside the avatars namespace — the route is unauthenticated', async () => {
    // Plant an object elsewhere in the bucket and prove it is NOT reachable:
    // this route must expose avatars and nothing else, whatever else the
    // bucket may hold now or later.
    await env.FORUM_MEDIA.put('private/secret.txt', 'not for you');

    for (const path of [
      '/media/private/secret.txt',
      '/media/avatars/../private/secret.txt',
      '/media/avatars/x/evil.svg',
    ]) {
      const res = await SELF.fetch(`${ORIGIN}${path}`);
      expect(res.status, path).toBe(404);
      await res.arrayBuffer();
    }
  });
});

describe('account deletion purges the avatar', () => {
  it("a deleted caregiver's face does not outlive their account", async () => {
    const profile = await bootstrap('cb-avatar-delete');
    await putAvatar('cb-avatar-delete', PNG_BYTES);
    expect(
      (await env.FORUM_MEDIA.list({ prefix: `avatars/${profile.id}/` })).objects,
    ).toHaveLength(1);

    const res = await authedFetch('/api/v1/profiles/me', {
      method: 'DELETE',
      sub: 'cb-avatar-delete',
    });
    expect(res.status).toBe(200);
    const { deleted } = (await res.json()) as {
      deleted: Record<string, number>;
    };
    expect(deleted.avatars).toBe(1);

    // The object is really gone from R2 — not just dereferenced by the row.
    expect(
      (await env.FORUM_MEDIA.list({ prefix: `avatars/${profile.id}/` })).objects,
    ).toHaveLength(0);
  });
});

describe('the author avatar rides along with forum content', () => {
  it('posts and comments carry author_avatar_url so the feed can render a face', async () => {
    await bootstrap('cb-avatar-author');
    const uploaded = await putAvatar('cb-avatar-author', PNG_BYTES);
    const { avatar_url } = (await uploaded.json()) as { avatar_url: string };

    const created = await authedFetch('/api/v1/posts', {
      method: 'POST',
      sub: 'cb-avatar-author',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        title: 'A post with a face',
        body: 'The feed should be able to show my avatar next to this.',
      }),
    });
    expect(created.status).toBe(201);
    const post = (await created.json()) as {
      id: string;
      author_avatar_url: string | null;
    };
    expect(post.author_avatar_url).toBe(avatar_url);

    // ...and on the read paths the feed actually uses.
    const feed = await SELF.fetch(`${ORIGIN}/api/v1/posts`);
    const rows = (await feed.json()) as {
      posts: Array<{ id: string; author_avatar_url: string | null }>;
    };
    expect(
      rows.posts.find((p) => p.id === post.id)?.author_avatar_url,
    ).toBe(avatar_url);

    const commented = await authedFetch(`/api/v1/posts/${post.id}/comments`, {
      method: 'POST',
      sub: 'cb-avatar-author',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: 'and on comments too' }),
    });
    expect(commented.status).toBe(201);
    expect(
      ((await commented.json()) as { author_avatar_url: string | null })
        .author_avatar_url,
    ).toBe(avatar_url);
  });
});

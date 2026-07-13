import { Hono } from 'hono';

// Public read-through for objects in the FORUM_MEDIA bucket — today, profile
// avatars.
//
// Why the Worker serves these instead of R2 doing it directly: a public R2
// bucket needs its own domain (a custom domain or an r2.dev subdomain) that
// has to be provisioned and DNS'd per environment. `R2_PUBLIC_URL` sat at the
// placeholder `media.holdclose.local` for exactly that reason — it resolved
// nowhere, so an avatar_url could never have loaded even if one had been set.
// Pointing R2_PUBLIC_URL at this route (`<worker origin>/media`) makes avatars
// work on every environment the Worker is deployed to, with no extra
// infrastructure. If a CDN-fronted bucket is provisioned later, only that var
// changes; nothing else here or in the app cares.
//
// Mounted at the WORKER ROOT (not under /api/v1) and deliberately EXEMPT from
// the forum JWT — the same posture as /join and the legal pages. An avatar is
// shown next to forum posts, and the post feed is read-anonymous per
// BUILD_SPEC §13, so requiring a session to load a face would break exactly
// the surface it exists for.
export type MediaBindings = {
  FORUM_MEDIA: R2Bucket;
};

// Only ever serve avatars. The bucket is a namespace we control, but this
// route is UNAUTHENTICATED, so it states its reachable surface explicitly
// rather than trusting that nothing private is ever written elsewhere in the
// bucket. `..` can't survive this pattern, so no traversal games either.
const AVATAR_KEY_PATTERN = /^avatars\/[A-Za-z0-9-]{1,64}\/[A-Za-z0-9-]{1,64}\.(jpg|png|webp)$/;

export const mediaRouter = () => {
  const router = new Hono<{ Bindings: MediaBindings }>();

  router.get('/*', async (c) => {
    // Everything after the mount point, e.g. `avatars/<profileId>/<uuid>.jpg`.
    const key = c.req.path.replace(/^\/media\//, '');
    if (!AVATAR_KEY_PATTERN.test(key)) {
      return c.json({ error: 'not_found' }, 404);
    }

    const object = await c.env.FORUM_MEDIA.get(key);
    if (!object) {
      return c.json({ error: 'not_found' }, 404);
    }

    const headers = new Headers();
    headers.set(
      'Content-Type',
      object.httpMetadata?.contentType ?? 'application/octet-stream',
    );
    // Keys are UUID-named and objects are never rewritten in place (a new
    // upload mints a new key and purges the old), so this is safe to cache
    // hard — and the app can lean on the URL alone to know the photo changed.
    headers.set(
      'Cache-Control',
      object.httpMetadata?.cacheControl ?? 'public, max-age=31536000, immutable',
    );
    headers.set('ETag', object.httpEtag);
    // The bytes are an image and nothing else — never let a browser sniff
    // this into something executable.
    headers.set('X-Content-Type-Options', 'nosniff');

    return new Response(object.body, { headers });
  });

  return router;
};

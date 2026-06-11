import type { MiddlewareHandler } from 'hono';
import { verify } from 'hono/jwt';
import { JwtTokenExpired } from 'hono/utils/jwt/types';

export type AuthBindings = {
  FORUM_JWT_SECRET: string;
};

export type AuthVariables = {
  userId: string;
};

export type ForumJwtPayload = {
  sub: string;
  iat: number;
  exp: number;
};

const BEARER_PREFIX = 'Bearer ';

export const auth = (): MiddlewareHandler<{
  Bindings: AuthBindings;
  Variables: AuthVariables;
}> => {
  return async (c, next) => {
    const header = c.req.header('Authorization');
    if (!header || !header.startsWith(BEARER_PREFIX)) {
      return c.json({ error: 'unauthorized' }, 401);
    }
    const token = header.slice(BEARER_PREFIX.length).trim();
    if (!token) {
      return c.json({ error: 'unauthorized' }, 401);
    }

    const secret = c.env.FORUM_JWT_SECRET;
    if (!secret) {
      return c.json({ error: 'server_misconfigured' }, 500);
    }

    let payload: ForumJwtPayload;
    try {
      payload = (await verify(token, secret, 'HS256')) as ForumJwtPayload;
    } catch (err) {
      if (err instanceof JwtTokenExpired) {
        // Distinguished so the client knows to silently re-auth.
        c.header('Token-Expired', 'true');
        return c.json({ error: 'token_expired' }, 401);
      }
      // EVERY other verify() failure — malformed token, bad signature,
      // wrong algorithm, nbf/iat violations, error classes a future hono
      // adds — means the caller is simply not authenticated. No rethrow:
      // nothing verify() throws is a server fault, so a rethrow's only
      // effect would be letting a hostile token manufacture a 500.
      return c.json({ error: 'unauthorized' }, 401);
    }

    if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
      return c.json({ error: 'unauthorized' }, 401);
    }

    c.set('userId', payload.sub);
    await next();
  };
};

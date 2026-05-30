import type { MiddlewareHandler } from 'hono';
import { verify } from 'hono/jwt';
import {
  JwtAlgorithmMismatch,
  JwtAlgorithmRequired,
  JwtHeaderInvalid,
  JwtTokenExpired,
  JwtTokenInvalid,
  JwtTokenIssuedAt,
  JwtTokenNotBefore,
  JwtTokenSignatureMismatched,
} from 'hono/utils/jwt/types';

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
        c.header('Token-Expired', 'true');
        return c.json({ error: 'token_expired' }, 401);
      }
      if (
        err instanceof JwtTokenInvalid ||
        err instanceof JwtTokenSignatureMismatched ||
        err instanceof JwtTokenNotBefore ||
        err instanceof JwtTokenIssuedAt ||
        err instanceof JwtHeaderInvalid ||
        err instanceof JwtAlgorithmMismatch ||
        err instanceof JwtAlgorithmRequired
      ) {
        return c.json({ error: 'unauthorized' }, 401);
      }
      throw err;
    }

    if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
      return c.json({ error: 'unauthorized' }, 401);
    }

    c.set('userId', payload.sub);
    await next();
  };
};

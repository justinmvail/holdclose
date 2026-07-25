import { Hono } from 'hono';

import type { Bindings, Variables } from '../index';

/// Escape a value for safe interpolation into HTML text / attributes.
/// Invite tokens are URL-safe today, but the landing page renders the raw
/// path segment, so we defensively escape rather than trust the shape.
function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/// Public care-circle invite landing page.
///
/// Mounted at the WORKER ROOT (`GET /join/:token`) and EXEMPT from the
/// forum JWT middleware — it's a plain, shareable web page the invited
/// caregiver opens from a text link. No DB work: it offers a
/// `holdclose://join/<token>` deep link that hands off to the app
/// (where the real join happens via the authed `POST /circles/join`,
/// behind an in-app confirmation). The raw token is deliberately NOT
/// echoed in the page body (2026-06-11) — it would linger in
/// screenshots/screen-shares; the share link itself already carries it
/// and invites are single-use + short-lived.
export function joinRouter() {
  const router = new Hono<{ Bindings: Bindings; Variables: Variables }>();

  router.get('/:token', (c) => {
    const token = c.req.param('token');
    const safe = escapeHtml(token);
    const deepLink = `holdclose://join/${safe}`;
    const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>You're invited to a care circle on Holdclose</title>
</head>
<body style="margin:0;background:#f8f6f3;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1f2a44;">
<div style="max-width:420px;margin:0 auto;padding:40px 24px;">
<h1 style="font-size:24px;line-height:1.3;margin:0 0 16px;">You're invited to a care circle on Holdclose</h1>
<p style="font-size:16px;line-height:1.5;margin:0 0 28px;color:#3a4a63;">Someone caring for a loved one wants to share the load with you. Open the app to join their circle.</p>
<a href="${deepLink}" style="display:block;text-align:center;background:#ff6900;color:#ffffff;text-decoration:none;font-size:18px;font-weight:700;padding:16px 20px;border-radius:14px;margin:0 0 28px;">Open in Holdclose</a>
<p style="font-size:14px;line-height:1.5;margin:0 0 28px;color:#3a4a63;">The app will ask you to confirm before you join. This invite works once and expires within two days.</p>
<p style="font-size:13px;line-height:1.5;margin:0;color:#7a869a;">Don't have the app yet? Ask the person who invited you.</p>
</div>
</body>
</html>`;
    return c.html(html);
  });

  return router;
}

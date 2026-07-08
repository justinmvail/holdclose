# Operator setup — the steps only a human with account access can do

Everything in this file is blocked on dashboard/console access (Google
Cloud, Cloudflare, App/Play stores) and cannot be scripted from the repo.
Each section says exactly what to click and what to update in the repo
afterwards. Status as of 2026-07-08.

## 1. Google OAuth clients for the new bundle id  ⟵ sign-in is broken until this

The rebrand changed the app id from `com.careblazers.careblazers` to
`com.holdclose.holdclose`. OAuth iOS/Android clients are bound to that id,
so "Continue with Google" fails in `AUTH=google` builds until new clients
exist. The **Web client is NOT bundle-bound and stays as-is** — it remains
both the app's `GOOGLE_SERVER_CLIENT_ID` and the Worker's verify audience,
so **no backend change is needed**.

In [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
(project number `187697773608`, account `justinmvail@gmail.com`):

1. **Create credentials → OAuth client ID → iOS**
   - Bundle ID: `com.holdclose.holdclose`
   - Note the new client id `<NEW_IOS_ID>.apps.googleusercontent.com`.
2. **Create credentials → OAuth client ID → Android**
   - Package name: `com.holdclose.holdclose`
   - SHA-1: `2A:1A:6E:B6:27:45:58:36:38:E3:F7:04:C4:65:25:93:CD:31:F9:0A`
     (the debug keystore — release APKs still sign with it; regenerate via
     the Corretto-17 keytool if ever needed, NOT the PATH Java 8).
   - Nothing in the repo bakes the Android id — the client just has to exist.
3. The old `com.careblazers.careblazers` iOS/Android clients can be deleted
   once no old builds remain in the field.

Then update the repo (the only two places the iOS id lives):

```bash
# tools/dev_defines.sh (gitignored):
GOOGLE_IOS_CLIENT_ID=<NEW_IOS_ID>.apps.googleusercontent.com
# ios/Runner/Info.plist — replace the reversed CFBundleURLSchemes entry:
com.googleusercontent.apps.<NEW_IOS_ID>
```

Reminder: the consent screen is in **Testing** mode — tester Gmails must be
listed under Audience → Test users until the app is published.

## 2. Cloudflare: enable R2, create buckets, set the chat secret

`wrangler` is already authenticated (`jcsvonellc@gmail.com`, account
`1d05533f4440827e2768c13a6c80c5ea`), but **R2 is not enabled on the
account** — bucket creation fails with code 10042 until you accept the R2
terms in the [dashboard](https://dash.cloudflare.com/) → R2 (needs a
payment method on file; the free tier covers alpha usage). Then, from
`backend/`:

```bash
npx wrangler r2 bucket create holdclose-forum-media   # FORUM_MEDIA
npx wrangler r2 bucket create holdclose-doc-blobs     # DOC_BLOBS
npx wrangler secret put CEREBRAS_API_KEY              # /api/v1/chat 500s without it
npm run deploy                                        # wrangler deploy
npx wrangler d1 migrations apply FORUM_DB --remote
```

(D1 binds by id and already exists — no data migration from the rename.)

## 3. holdclose.care routing

`holdclose.care` currently has no DNS records. For the Worker to serve the
public pages (`/join` invite landing, `/terms`, `/privacy`) at the brand
domain: add the zone to the Cloudflare account, then attach a custom
domain to the `holdclose-forum` Worker (Workers & Pages → holdclose-forum →
Settings → Domains & Routes → `holdclose.care`). The app already links to
`https://holdclose.care/terms` + `/privacy`; those 404/NXDOMAIN until this
step.

## 4. Store track (later phase, in order)

1. Apple Developer Program + Google Play Console **organization**
   enrollment under JCSV One LLC (D-U-N-S 13-689-7602) — see the plan on
   the Desktop; publisher DBA must not be "Careblazers".
2. Real release signing for Android (replace the debug-keystore signing in
   `android/app/build.gradle.kts`) + register the release SHA-1 on the
   OAuth Android client.
3. Paywall (StoreKit / Play Billing) + rev-share affiliate attribution —
   gated on #1; a build-out phase of its own.

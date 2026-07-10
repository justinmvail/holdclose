# Holdclose — Roadmap to Production

_The path from "hardened working alpha" (where we are today, 2026-07-09) to a
shipped, paid production app. Ordered by milestone; check items off as they land._

**Ownership:** 👤 = only the founder can do it (accounts, legal, real people,
decisions) · 🖥️ = operator/console step (founder runs it; Claude gives exact
steps) · 🤖 = Claude can do it in-repo · 🤝 = shared.

**Status:** `[ ]` open · `[~]` partly done · `[x]` done this session.

---

## ✅ Already done this session (context — don't redo)
- [x] Critical security hole (shim `@path` file-read) fixed + live shim reloaded.
- [x] Chat/voice: every data-changing action gated behind the confirm card; honest failure reporting; code-side crisis watchdog; uncertainty flagging.
- [x] AI surfaces: prompt-injection sanitizing, recap AI-label, scanned-field uncertainty flags.
- [x] Accessibility: WCAG CTA contrast, OS font-scale composition, first-run Home, hit targets.
- [x] Android reminders fixed (manifest receivers) + release-signing config wired (debug fallback).
- [x] Real cascading account deletion (backend `DELETE /profiles/me` + client); iOS backup exclusion; on-device crash capture; data restore (iOS); subprocessor disclosure; shim rate limiting.
- [x] DOB, weight, Terms/Privacy pages, care-summary fix, share-link, find-provider overhaul.
- [x] Build 28 verified on iPhone + Android tester APK; full suite green (1926 Flutter + 343 backend).
- [x] Competition: cover+abstract, overclaims rewritten, Smart-40 Data Output Logs (41/41), full contest-site scrape (`CONTEST_MASTER_REFERENCE.md`).

---

## Milestone 0 — Consolidate everything under JCSV One LLC
_Ownership hygiene: get the code, the AI subscription, and the auth all under the
company identity before store enrollment + payout. Do these early — later steps
(OAuth, payout, App/Play accounts) assume the LLC owns things._
- [ ] 👤 **Create the JCSV GitHub org/account** and **migrate the `holdclose` repo** to it (GitHub repo → Settings → Transfer ownership; GitHub redirects the old `justinmvail/holdclose` URL). Then `git remote set-url origin` locally + update `CLAUDE.md`/memory. Move any CI/secrets with it.
- [ ] 👤 **Move the Claude subscription to the JCSV Google account + JCSV bank account** (the dev shim runs on this subscription; billing under the LLC). If AI moves fully to Cloudflare Workers AI (Milestone 1c), the Claude sub becomes dev-tooling-only — still cleaner under the LLC.
- [ ] 👤 **Google auth under the JCSV Google account** — own the GCP project (187697773608) from `jcsvonellc@gmail.com` (grant Owner, accept, then create the new `com.holdclose.holdclose` OAuth clients from the LLC account per `OPERATOR_SETUP.md §1`). One identity for OAuth, Play, and payout.
- [ ] 🖥️ Cloudflare is already under `jcsvonellc@gmail.com` — confirm the R2/Workers billing + payment method are on the LLC.

## Milestone 1 — Production launch blockers

### 1a. Identity & sign-in
- [ ] 🖥️ **Create Google OAuth iOS + Android clients for `com.holdclose.holdclose`** (project 187697773608). Sign-in is broken in `AUTH=google` builds until this exists. Steps in `docs/OPERATOR_SETUP.md §1`. → paste the iOS client id to Claude to wire `Info.plist` + `dev_defines.sh`.
- [ ] 👤 **Decide entrant/publisher identity** — individual vs. JCSV One LLC entity (affects OAuth ownership, store accounts, prize payout). Grant the LLC Owner on the GCP project if going the entity route.

### 1b. Cloudflare backend deploy — runbook
_Worker is built + tested (343 vitest green); it just needs a production deploy.
`wrangler` is already authenticated as `jcsvonellc@gmail.com`, account `1d05533f…`._
- [ ] 🖥️ **Enable R2** on the Cloudflare account (dashboard → R2; blocked today with code 10042 until R2 terms accepted + a payment method on file — free tier covers alpha).
- [ ] 🖥️ From `backend/`: `npx wrangler r2 bucket create holdclose-forum-media` and `… holdclose-doc-blobs`.
- [ ] 🖥️ Set Worker **secrets**: `wrangler secret put FORUM_JWT_SECRET` and the watchdog keys `CLOUDFLARE_API_TOKEN` + `RESEND_API_KEY`. (No inference key — AI runs on the key-less Workers AI `AI` binding; see 1c.)
- [ ] 🖥️ Confirm/override non-secret `[vars]` in `wrangler.toml` for prod: `GOOGLE_CLIENT_ID` (web + iOS ids), `R2_PUBLIC_URL`, watchdog account/bucket ids, `RESEND_FROM/TO_EMAIL`.
- [ ] 🖥️ `npm run deploy` (wrangler deploy) → then `npx wrangler d1 migrations apply FORUM_DB --remote`. (D1 binds by id and already exists — no data migration from the rebrand.)
- [ ] 🖥️ **Custom domain:** attach `holdclose.care` (and/or `api.holdclose.care`) to the Worker (Workers & Pages → holdclose-forum → Domains & Routes). Add the zone to Cloudflare first — no DNS records exist yet.
- [ ] 🤝 Point the app's `FORUM_API_URL` build-define at the production origin (drop the Tailscale-funnel `:8443`).
- [ ] 🤖 **Smoke-test prod:** `/health`, `/terms`, `/privacy`, a sign-in → JWT mint, a sync push/pull, `DELETE /profiles/me`, and a `/api/v1/chat` turn.
- [ ] 🖥️ Turn off the alpha Tailscale-funnel LaunchAgents once testers are on the prod backend (or keep for a staging tier).

### 1c. Production AI — move EVERYTHING to Cloudflare Workers AI (DECIDED)
_Decision: one AI provider, Cloudflare Workers AI, via the key-less `AI` binding.
Retire Cerebras and drop the dev shim from the production path. Rationale: no API
key to manage or leak; the PHI prompt/image never leaves Cloudflare's network
(where the Worker + D1 + R2 already live) → **only one AI subprocessor, and it's
our own infra** — the strongest possible privacy story for the competition and
the stores. Today chat + recap route through the Worker `/chat`; the scanners,
visit-prep, and insurance-appeal still hit the dev shim only._

**⚠️ Validation caveat:** Workers AI models are smaller than the frontier
model the dev shim uses, so chat quality/latency and scan-extraction accuracy
**must be validated on the live account at deploy** — can't be tested from the
dev environment. The backend is built + fully unit-tested (346 green) against a
mocked endpoint; real-inference quality is a deploy-time check.

- [x] 🤖 **Backend chat inference → Workers AI** (commit `dd09361`). `chat.ts` now calls Cloudflare Workers AI's **OpenAI-compatible endpoint** (`…/accounts/<id>/ai/v1/chat/completions`) with `@cf/meta/llama-3.3-70b-instruct-fp8-fast`; kept the vendor-neutral `data:{"text":…}` SSE + spend caps. Serves chat, recap, visit-prep, and insurance-appeal. _(Used the REST endpoint, not the key-less `AI` binding, because the binding can't start in the vitest-pool-workers test runtime — so a `CF_AI_API_TOKEN` secret is needed. Still 100% Cloudflare Workers AI.)_
- [x] 🤖 **New `POST /api/v1/extract` (vision)** (commit `dd09361`) — JWT-gated, calls the same endpoint with `@cf/meta/llama-3.2-11b-vision-instruct` (image via the OpenAI `image_url` message), same per-user quota/caps, returns the model's JSON text (the shim `/extract` contract). 3 new tests.
- [x] 🤖 **Privacy disclosure + packet** updated to Cloudflare Workers AI (`legal.ts` subprocessor; packet swept by the evidence pass — commit `8f08a9f`).
- [x] 🤖 **App already routes all AI through the Worker in production** — no code change needed. Every surface has a Worker-backed impl selected when `FORUM_API_URL` is baked in: `ApiChatBackend` (chat + recap → `/api/v1/chat`), `ApiPrescriptionScanner` / `ApiAppointmentScanner` / `ApiInsuranceCardScanner` (→ `/api/v1/extract`, via `document_scan_transport.workerExtractJson`), and `ApiVisitPrepService` / `ApiInsuranceAppealService` (→ the Worker). These were dormant only because `/extract` didn't exist and chat pointed at Cerebras — the backend migration activated them. The shim is used only when NO backend is configured (dev).
- [ ] 🖥️ **Store builds: don't bake `SHIM_URL`/`SHIM_TOKEN`.** Pass only `FORUM_API_URL` (→ Worker path); omit the shim defines so no extractable token ships. Build-script discipline, not a code change.
- [ ] 🤝 **Deploy-time validation:** with the Worker live, exercise every AI surface (chat, voice-intent, recap, all three scanners, visit-prep, appeal); judge chat quality + scan accuracy; if extraction is weak, swap `EXTRACT_MODEL`/`CHAT_MODEL` (a wrangler var) or keep a frontier fallback for scans only.
- [ ] 🖥️ **Set `CF_AI_API_TOKEN`** (Cloudflare API token, "Workers AI: Read") + fill `CLOUDFLARE_ACCOUNT_ID` at deploy (see `OPERATOR_SETUP.md §2`).

### 1d. Real release signing & store accounts
- [ ] 👤 **Apple Developer Program + Google Play Console enrollment** under the chosen publisher (org enrollment for JCSV One LLC; D-U-N-S 13-689-7602). Multi-week — start now; it gates everything in 1e/1f.
- [ ] 🖥️ **Android release keystore:** generate one (secure password, Corretto-17 keytool) → `android/holdclose-release.keystore` + `android/key.properties` (both gitignored; `build.gradle.kts` already reads them, debug-fallback when absent). Register its **SHA-1 on the OAuth Android client**. Steps in `OPERATOR_SETUP.md §4.2`.
- [ ] 👤 **Apple signing:** App ID `com.holdclose.holdclose`, distribution certificate, App Store provisioning profile (Xcode-managed is fine).

### 1e. App Store (iOS) — submission runbook
- [ ] 👤 In App Store Connect: create the app record (bundle id `com.holdclose.holdclose`), name "Holdclose", primary category, subtitle.
- [ ] 🤝 **App Privacy ("nutrition labels")** — declare: health data collected + linked to identity; on-device storage; the **Cloudflare Workers AI subprocessor** (AI on our own infra, no separate vendor); no sale, no ads; account deletion supported. Claude drafts from the privacy policy; founder submits.
- [ ] 👤 **Account-deletion requirement (5.1.1(v))** — the in-app "Delete account" now truly cascades server-side; point the reviewer to it.
- [ ] 🤝 Store listing: description, keywords, support URL (`holdclose.care`), marketing URL, promotional text, 6.5"/5.5" screenshots + iPad if universal, optional app preview.
- [ ] 👤 Age rating questionnaire; **export-compliance** (uses standard HTTPS/OS crypto — usually the exemption); content-rights.
- [ ] 🖥️ Archive a real-signed build (`tools/build_ipa.sh`), upload via Xcode/Transporter → **TestFlight** (internal, then external pilot) → submit for App Review.
- [ ] 🤖 Pre-submit sweep: no vendor/model names in UI, disclaimer present, medical guardrails intact, deep-links + notifications work on a clean install.

### 1f. Google Play (Android) — submission runbook
- [ ] 👤 In Play Console: create the app, set up the **closed testing → open testing** tracks (Play now requires a testing period before production for new personal/org accounts).
- [ ] 🤝 **Data safety form** — mirror the iOS privacy labels (health data, encryption in transit, on-device storage, Cerebras subprocessor, deletion via in-app + support email).
- [ ] 👤 Content rating (IARC) questionnaire; target-audience; ads declaration (none); a **public privacy-policy URL** = `holdclose.care/privacy` (needs 1b DNS live).
- [ ] 🤖 **Build an AAB** (`flutter build appbundle --release`) — Play splits per-ABI so the ~195 MB fat APK shrinks to per-device downloads automatically; real-signed via `key.properties`.
- [ ] 🖥️ Upload to internal testing → promote through closed/open → production. Enroll in **Play App Signing**.
- [ ] 🤝 Listing: short/full description, feature graphic, phone + tablet screenshots, category, contact details.

---

## Milestone 2 — Production hardening (around launch)
- [x] 🤖 **At-rest DB encryption — SQLCipher** (commit `c488cf6`). Local DB now encrypted; 256-bit key minted on first run + stored in Keychain/Keystore (`flutter_secure_storage`); existing plaintext installs auto-migrate in place (ATTACH + `sqlcipher_export`, crash-safe swap). In-memory test path stays unencrypted (suite unaffected). Privacy policy/packet updated to "encrypted at rest." → 🖥️ **needs device validation:** `cd ios && pod install` (new pod), then install a plaintext build (28) with data → install this branch → confirm the data survived the migration. Watch for a native sqlite3/SQLCipher link collision on the first device build (Dart-level override handles it; a Podfile/Gradle `pickFirst` nudge is the fallback).
- [ ] 🤖 **Android "Restore from backup" file picker** — iOS-only today; add a Kotlin `ACTION_OPEN_DOCUMENT` bridge for parity.
- [x] 🤖 **Crash-report aggregation** (commit `bec54ed`) — both channels now: the on-device user-initiated report **plus** automatic `sentry_flutter` behind a `--dart-define=SENTRY_DSN` (empty = off, so dev/test/demo send nothing). `beforeSend` scrubs PHI (no message bodies, care data, or email/name — only exception type + stack + os/version). No vendor name in the UI (dev-facing). → 🖥️ **operator:** stand up a self-hosted Sentry, get the DSN, add `SENTRY_DSN` to the release build defines.
- [ ] 🤖 **Dependency refresh** — 104 packages behind; sweep majors with the suite as the gate.
- [ ] 🤝 **Load/cost check** on the Worker `/chat` spend caps before opening to real volume.

---

## Milestone 3 — Business model (monetization phase)
_Paid-subscription + affiliate plan; gated on org enrollment (1d)._
- [ ] 👤 **Pricing decision** — free core tier + subscription tiers/price points.
- [x] 🤖 **Paywall built + server-verified** (commits `0ab25e4`, `ac4a925`, `104a427`) — `in_app_purchase` scaffold (always-a-free-trial) **plus** server-side receipt verification: `POST /api/v1/billing/verify` validates the receipt directly with Apple's App Store Server API + Google's Play Developer API and persists the authoritative entitlement in a D1 `entitlements` table; `GET /api/v1/billing/entitlement` is the app's launch-time source of truth. **The device no longer self-grants premium** — a jailbroken client can't fake it (offline falls back to the last *server* value). Fake billing stays the default with no backend, so tests/demo are unchanged. → remaining: (a) 👤 **create the subscription products** (price points + IDs) in App Store Connect + Play Console + replace the placeholder constants, (b) 👤 decide which features go premium (then 🤖 wrap with `PremiumGate`).
  - 🖥️ **Operator secrets for verify:** Apple — `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `wrangler secret put APPLE_PRIVATE_KEY` (App Store Connect `.p8`), `APPLE_BUNDLE_ID`; Google — `GOOGLE_PLAY_SA_EMAIL`, `wrangler secret put GOOGLE_PLAY_SA_PRIVATE_KEY` (Play service account), `GOOGLE_PLAY_PACKAGE`.
  - 🖥️ **Device validation:** a real StoreKit/Play sandbox purchase → `/billing/verify` round-trip → premium reflects the server; kill+relaunch hydrates from `getEntitlement`; test Restore + airplane-mode (holds the cached server value).
- [ ] 🤝 **Rev-share affiliate attribution** — per-creator referral codes → commission on *paying* subscribers; attribution backend + creator dashboard.
- [ ] 👤 Tax/payout setup + terms for the affiliate program.

---

## Competition track — ACL Caregiver AI Challenge (HARD deadline: July 31, 2026, 5pm ET)
_Parallel to the above; winning Phase 1 funds Milestones 2–3. Details in `SUBMISSION_TODO.md` + `CONTEST_MASTER_REFERENCE.md`._

**Founder-only:**
- [ ] 👤 Cover page: legal name, email, phone, **U.S. citizen/PR attestation**, Track 1.
- [ ] 👤 **Bio sketch** (§2) — VBMS/VA experience, veteran, caregiving-for-father; confirm accurate + OK to publish.
- [ ] 👤 **Tester evidence** — fill `FEEDBACK_LOG.md` with real caregiver quotes + consent; the real `[N]` counts; 1–2 more feedback-driven changes.
- [ ] 👤 **Recruit 3–5 more caregivers** (incl. ≥1 dementia caregiver if keeping §5) via `recruiting_kit.md`; send `outreach_email.md` + collect 2–3 letters of support.
- [ ] 👤 §5 dementia merit: **keep-with-evidence or drop** (recommendation in `SUBMISSION_TODO.md`). (Optional: SAM.gov UEI. The ACL clarification email is NOT required — no real eligibility conflict.)

**Claude-doable:**
- [ ] 🤖 **Weave the CAN 2026 survey stats into §1 + §4** (judging-partner data; use-cases map 1:1 to our features) — biggest evidence upgrade available.
- [ ] 🤖 Add a **Net-Time-Saved estimate** + an **Actionable Workflow diagram** (Input→AI→Caregiver Action) + **bench metrics** (F1/precision/recall for the scan classifiers; coach = 41/41 guardrail pass-rate).
- [ ] 🤖 **Convert `DATA_OUTPUT_LOGS.md` → PDF/Word** (markdown isn't an accepted final format).
- [ ] 🤝 **Final 508-compliant assembly** — cover + §1–§5 + appendix → one PDF/Word, ≥11pt, 1-inch margins, page numbers; one email to CaregiverAI@acl.hhs.gov.

---

## Backlog / polish (post-launch, non-blocking)
- [ ] 🤖 Localization — the AI surfaces (chat, voice, recap, visit-prep, appeal) now reply in whatever language the caregiver writes/speaks, so multilingual coaching ships for free. UI strings are English-first with a partial `es` stub (`lib/l10n/app_es.arb` — common/nav/sign-in; missing keys fall back to en). Remaining work: translate the full `es` UI (Spanish-first for the ACL population is the highest-value locale).
- [ ] 🤖 Remaining low-severity audit items (`DEEP_DIVE_AUDIT.md` Tier 3/4); notification-scheduling-failure surfacing.
- [ ] 🤝 Retire stale docs (BUILD_SPEC/TASKS predate the pivot); model-level cleanup of dead `Patient.calms/escalates` + `PdfExporter.crisisCard`.

---

### The critical path, in one line
**Consolidate under JCSV (GitHub, Claude sub, Google/Cloudflare accounts) → Google OAuth clients → Cloudflare deploy (R2 + secrets + DNS) → move all AI to Cloudflare Workers AI (key-less `AI` binding: Llama-3.3-70B text + Moondream vision; drop Cerebras + the shim) → store enrollment + real signing → App Store & Play submissions (privacy forms, pilots, review) → paywall → public launch.** The competition runs in parallel and, if won in September, funds Milestones 2–3.

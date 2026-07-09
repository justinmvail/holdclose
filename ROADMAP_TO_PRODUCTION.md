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

## Milestone 1 — Production launch blockers

### 1a. Identity & sign-in
- [ ] 🖥️ **Create Google OAuth iOS + Android clients for `com.holdclose.holdclose`** (project 187697773608). Sign-in is broken in `AUTH=google` builds until this exists. Steps in `docs/OPERATOR_SETUP.md §1`. → paste the iOS client id to Claude to wire `Info.plist` + `dev_defines.sh`.
- [ ] 👤 **Decide entrant/publisher identity** — individual vs. JCSV One LLC entity (affects OAuth ownership, store accounts, prize payout). Grant the LLC Owner on the GCP project if going the entity route.

### 1b. Cloudflare backend deploy — runbook
_Worker is built + tested (343 vitest green); it just needs a production deploy.
`wrangler` is already authenticated as `jcsvonellc@gmail.com`, account `1d05533f…`._
- [ ] 🖥️ **Enable R2** on the Cloudflare account (dashboard → R2; blocked today with code 10042 until R2 terms accepted + a payment method on file — free tier covers alpha).
- [ ] 🖥️ From `backend/`: `npx wrangler r2 bucket create holdclose-forum-media` and `… holdclose-doc-blobs`.
- [ ] 🖥️ Set Worker **secrets**: `wrangler secret put FORUM_JWT_SECRET`, `wrangler secret put CEREBRAS_API_KEY` (see 1c), and the watchdog keys `CLOUDFLARE_API_TOKEN` + `RESEND_API_KEY`.
- [ ] 🖥️ Confirm/override non-secret `[vars]` in `wrangler.toml` for prod: `GOOGLE_CLIENT_ID` (web + iOS ids), `R2_PUBLIC_URL`, watchdog account/bucket ids, `RESEND_FROM/TO_EMAIL`.
- [ ] 🖥️ `npm run deploy` (wrangler deploy) → then `npx wrangler d1 migrations apply FORUM_DB --remote`. (D1 binds by id and already exists — no data migration from the rebrand.)
- [ ] 🖥️ **Custom domain:** attach `holdclose.care` (and/or `api.holdclose.care`) to the Worker (Workers & Pages → holdclose-forum → Domains & Routes). Add the zone to Cloudflare first — no DNS records exist yet.
- [ ] 🤝 Point the app's `FORUM_API_URL` build-define at the production origin (drop the Tailscale-funnel `:8443`).
- [ ] 🤖 **Smoke-test prod:** `/health`, `/terms`, `/privacy`, a sign-in → JWT mint, a sync push/pull, `DELETE /profiles/me`, and a `/api/v1/chat` turn.
- [ ] 🖥️ Turn off the alpha Tailscale-funnel LaunchAgents once testers are on the prod backend (or keep for a staging tier).

### 1c. Production AI API — runbook
_Today: the **coach chat** and the **Home recap** already route through the Worker
`POST /api/v1/chat` → **Cerebras (gpt-oss-120b)**, spend-capped, key server-side.
But the **document scanners** (prescription/appointment/insurance-card),
**visit-prep**, and **insurance-appeal** still call the **dev shim only** — they
have NO production route and will break in a store build. On-device TTS (Piper)
has no server dependency. This is the biggest production-AI gap._
- [ ] 👤 **Provision production inference:** a Cerebras account + `CEREBRAS_API_KEY` (or chosen provider); confirm contractual **no-retention / no-training** terms (already stated in the privacy policy).
- [ ] 🤖 **Build Worker routes for the shim-only AI surfaces** so nothing depends on the funnel shim in production:
  - Document **scan/extract** — a JWT-gated `/api/v1/extract` (or extend `/chat`) that accepts the image + extraction prompt. **Note:** extraction needs a **vision-capable** model — verify gpt-oss-120b/Cerebras supports image input; if not, wire a vision model here (this is a real architecture decision, not a config toggle).
  - **Visit-prep** and **insurance-appeal** generative calls — route through `/chat` (they're text-only) with their existing prompts.
- [ ] 🤖 **Point the app's production AI at the Worker, not the shim:** in store builds select `ApiChatBackend` + the Worker extract/generate endpoints; **drop `SHIM_URL` and the baked `SHIM_TOKEN`** entirely (they're an extractable-secret liability). The dev shim stays a dev-only convenience.
- [ ] 🤖 **Extend spend caps + abuse protection** (already on `/chat`) to the new extract route; per-account quotas; graceful "coach is busy, try again" UX on 429/5xx.
- [ ] 🤝 **Cost model + monitoring:** per-feature token budgets, the weekly watchdog thresholds, and an alert before the Cerebras bill runs away.
- [ ] 🤖 Regression-test every AI surface against the prod API (chat, voice-intent, recap, all three scanners, visit-prep, appeal) with `USE_FAKE_LLM=false` pointed at prod.

### 1d. Real release signing & store accounts
- [ ] 👤 **Apple Developer Program + Google Play Console enrollment** under the chosen publisher (org enrollment for JCSV One LLC; D-U-N-S 13-689-7602). Multi-week — start now; it gates everything in 1e/1f.
- [ ] 🖥️ **Android release keystore:** generate one (secure password, Corretto-17 keytool) → `android/holdclose-release.keystore` + `android/key.properties` (both gitignored; `build.gradle.kts` already reads them, debug-fallback when absent). Register its **SHA-1 on the OAuth Android client**. Steps in `OPERATOR_SETUP.md §4.2`.
- [ ] 👤 **Apple signing:** App ID `com.holdclose.holdclose`, distribution certificate, App Store provisioning profile (Xcode-managed is fine).

### 1e. App Store (iOS) — submission runbook
- [ ] 👤 In App Store Connect: create the app record (bundle id `com.holdclose.holdclose`), name "Holdclose", primary category, subtitle.
- [ ] 🤝 **App Privacy ("nutrition labels")** — declare: health data collected + linked to identity; on-device storage; the **Cerebras subprocessor**; no sale, no ads; account deletion supported. Claude drafts from the privacy policy; founder submits.
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
- [ ] 👤 **At-rest DB encryption decision.** Local SQLite is plaintext PHI (mitigated by OS device encryption + backup exclusion). Adopt SQLCipher (`sqlcipher_flutter_libs` + key in Keychain/Keystore) or keep the honest "OS-protected" posture — drives the store privacy claims.
- [ ] 🤖 **Android "Restore from backup" file picker** — iOS-only today; add a Kotlin `ACTION_OPEN_DOCUMENT` bridge for parity.
- [ ] 🤝 **Crash-report aggregation** — on-device capture ships; decide whether to add a privacy-respecting aggregator (self-hosted Sentry, PII-scrubbed) or keep user-initiated-only (no-vendor-name rule applies).
- [ ] 🤖 **Dependency refresh** — 104 packages behind; sweep majors with the suite as the gate.
- [ ] 🤝 **Load/cost check** on the Worker `/chat` spend caps before opening to real volume.

---

## Milestone 3 — Business model (monetization phase)
_Paid-subscription + affiliate plan; gated on org enrollment (1d)._
- [ ] 👤 **Pricing decision** — free core tier + subscription tiers/price points.
- [ ] 🤖 **Paywall** — `in_app_purchase` (StoreKit + Play Billing); gate the premium surface; restore-purchases; receipt validation.
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
- [ ] 🤖 Localization — English-only today; Spanish-first (ACL population) is the highest-value locale.
- [ ] 🤖 Remaining low-severity audit items (`DEEP_DIVE_AUDIT.md` Tier 3/4); notification-scheduling-failure surfacing.
- [ ] 🤝 Retire stale docs (BUILD_SPEC/TASKS predate the pivot); model-level cleanup of dead `Patient.calms/escalates` + `PdfExporter.crisisCard`.

---

### The critical path, in one line
**Google OAuth clients → Cloudflare deploy (R2 + secrets + DNS) → production AI API (provision key + build the missing extract/visit-prep/appeal routes + drop the shim) → store enrollment + real signing → App Store & Play submissions (privacy forms, pilots, review) → paywall → public launch.** The competition runs in parallel and, if won in September, funds Milestones 2–3.

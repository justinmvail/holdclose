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
_Everything that must be TRUE to put a real, signed, working build in the stores._

### 1a. Identity & sign-in
- [ ] 🖥️ **Create Google OAuth iOS + Android clients for `com.holdclose.holdclose`** (project 187697773608). Sign-in is broken in `AUTH=google` builds until this exists. Steps in `docs/OPERATOR_SETUP.md §1`. → paste the iOS client id to Claude to wire `Info.plist` + `dev_defines.sh`.
- [ ] 👤 **Decide entrant/publisher identity** — individual vs. JCSV One LLC entity (affects OAuth ownership, store accounts, prize payout). Grant the LLC account Owner on the GCP project if going the entity route.

### 1b. Backend production deploy (Cloudflare)
- [ ] 🖥️ **Enable R2** on the Cloudflare account (dashboard; currently blocked with code 10042 — needs a payment method).
- [ ] 🖥️ Create buckets `holdclose-forum-media` + `holdclose-doc-blobs`.
- [ ] 👤 **Obtain a `CEREBRAS_API_KEY`** (production coach inference) → `wrangler secret put CEREBRAS_API_KEY`.
- [ ] 🖥️ Set remaining Worker secrets: `FORUM_JWT_SECRET`, watchdog keys (`CLOUDFLARE_API_TOKEN`, `RESEND_API_KEY`).
- [ ] 🖥️ `npm run deploy` + `wrangler d1 migrations apply FORUM_DB --remote`. (D1 binds by id — no data migration from the rename.)
- [ ] 🖥️ **Point `holdclose.care` DNS at the Worker** (custom domain) so `/terms`, `/privacy`, and `/join` invite links resolve — required for store review + the sign-in legal links.
- [ ] 🤖 After deploy: smoke-test prod chat, sync, account-delete, and the legal pages end-to-end.

### 1c. Real release signing & store enrollment
- [ ] 👤 **Apple Developer Program + Google Play Console enrollment** under the chosen publisher (org enrollment for JCSV One LLC; D-U-N-S 13-689-7602). Multi-week; start now.
- [ ] 🖥️ **Generate a real Android release keystore** (secure password, Corretto-17 keytool) → `android/holdclose-release.keystore` + `android/key.properties` (both gitignored; config already reads them). Register its SHA-1 on the OAuth Android client. Steps in `OPERATOR_SETUP.md §4.2`.
- [ ] 👤 Apple: create the App ID `com.holdclose.holdclose`, provisioning, and a distribution cert.

### 1d. Store listings & compliance
- [ ] 🤝 **App Store privacy nutrition labels + Google Play Data Safety form** — declare PHI handling, on-device storage, the Cerebras subprocessor, no-sale/no-ads. (Claude can draft from the privacy policy; founder submits.)
- [ ] 🤝 Store listing copy, screenshots (all required sizes), app preview, keywords, category, support URL, marketing URL (`holdclose.care`).
- [ ] 👤 Age rating questionnaires; export-compliance (encryption) declaration.
- [ ] 🤖 Confirm bundle id, display name, version, and icons are store-correct (Hc icon already shipped).
- [ ] 🖥️ First TestFlight (iOS) + Play Internal Testing (Android) upload from real-signed builds; then a small external pilot.

---

## Milestone 2 — Production hardening (around launch)
_Recommended before a wide public release; the remaining audit tiers._

- [ ] 🤝 **Retire the dev shim from production builds.** Prod chat should go only through the quota-capped Worker `/api/v1/chat` (Cerebras), not the funnel shim + baked `SHIM_TOKEN`. Drop `SHIM_TOKEN`/`SHIM_URL` from store builds. (`llm_provider.dart`.)
- [ ] 👤 **At-rest DB encryption decision.** Local SQLite is plaintext PHI today (mitigated by OS device encryption + backup exclusion). Either adopt SQLCipher (`sqlcipher_flutter_libs` + key in Keychain/Keystore) or keep the honest "OS-protected" posture. Decision drives the store privacy claims.
- [ ] 🤖 **Android "Restore from backup" file picker** — currently iOS-only (no `file_picker` dep); add a Kotlin `ACTION_OPEN_DOCUMENT` bridge so Android parity.
- [ ] 🤝 **Crash-report aggregation.** On-device capture ships; decide whether to add a privacy-respecting aggregator (self-hosted Sentry with PII scrubbing) or keep user-initiated-only — the no-vendor-name rule applies.
- [ ] 🤖 **Dependency refresh** — 104 packages behind; sweep majors (Flutter/plugins) with the suite as the gate.
- [ ] 🤖 **App size** — 195 MB is mostly the bundled Piper voice. AAB splits shrink store downloads automatically; consider making the neural voice an on-demand download to cut the base further.
- [ ] 🤝 **Load/cost check** on the Worker `/chat` spend caps before opening the funnel to real volume.

---

## Milestone 3 — Business model (monetization phase)
_The pivot's paid-subscription + affiliate plan; gated on org enrollment (1c)._

- [ ] 👤 **Pricing decision** — free core tier + subscription tiers/price points.
- [ ] 🤖 **Paywall** — `in_app_purchase` (StoreKit + Play Billing); gate the premium surface; restore-purchases; receipt validation.
- [ ] 🤝 **Rev-share affiliate attribution** — per-creator referral codes → commission on *paying* subscribers; needs an attribution backend + a creator dashboard.
- [ ] 👤 Tax/payout setup for affiliates; terms for the affiliate program.

---

## Competition track — ACL Caregiver AI Challenge (HARD deadline: July 31, 2026, 5pm ET)
_Parallel to the above; winning Phase 1 funds the rest. Details in `SUBMISSION_TODO.md` + `CONTEST_MASTER_REFERENCE.md`._

### Founder-only (nobody else can supply)
- [ ] 👤 Cover page: legal name, email, phone, **U.S. citizen/PR attestation**, Track 1.
- [ ] 👤 **Bio sketch** (§2) — VBMS/VA experience, veteran, caregiving-for-father details; confirm accurate + OK to publish.
- [ ] 👤 **Tester evidence** — fill `FEEDBACK_LOG.md` with real caregiver quotes + consent-to-cite; the real `[N]` counts; 1–2 more feedback-driven changes. (User-Centered scores ~zero without this.)
- [ ] 👤 **Recruit 3–5 more caregivers** (incl. ≥1 dementia caregiver if keeping §5) via `recruiting_kit.md`.
- [ ] 👤 **Send `outreach_email.md`** (letters of support) + collect 2–3 letters for the appendix.
- [ ] 👤 (Optional) SAM.gov UEI to expedite payout; (optional) the ACL clarification email — **not required** (no real eligibility conflict; see this session's analysis).
- [ ] 👤 §5 dementia merit: **keep-with-evidence or drop** (recommendation in `SUBMISSION_TODO.md`).

### Claude-doable (drafting/evidence)
- [ ] 🤖 **Weave the CAN 2026 survey stats into §1 + §4** (the judging partner's own data; use-cases map 1:1 to our features). Biggest evidence upgrade available.
- [ ] 🤖 Add a **Net-Time-Saved estimate** and an **Actionable Workflow diagram** (Input→AI→Caregiver Action) — both suggested by the Tech Guide, currently missing.
- [ ] 🤖 Add **basic bench metrics** (F1/precision/recall for the scan-extraction classifiers; coach = the 41/41 guardrail pass-rate).
- [ ] 🤖 **Convert `DATA_OUTPUT_LOGS.md` → PDF/Word** (markdown is not an accepted final format).
- [ ] 🤝 **Final 508-compliant assembly** — merge cover + §1–§5 + appendix into one PDF/Word, ≥11pt, 1-inch margins, page numbers; verify against the outline headings. Email one per application to CaregiverAI@acl.hhs.gov.

---

## Backlog / polish (post-launch, non-blocking)
- [ ] 🤖 Localization — English-only today; Spanish-first (ACL population) is the highest-value locale.
- [ ] 🤖 Remaining low-severity audit items (jargon copy, delete-recovery UI, etc. — see `DEEP_DIVE_AUDIT.md` Tier 3/4).
- [ ] 🤖 Broaden test coverage on the newest surfaces; wire the notification-scheduling-failure surfacing the Android agent flagged as a cross-agent gap.
- [ ] 🤝 Retire/consolidate stale docs (BUILD_SPEC/TASKS predate the pivot).
- [ ] 👤 Model-level cleanup of the dead `Patient.calms/escalates` fields + `PdfExporter.crisisCard` (production-dead) when convenient.

---

### The critical path, in one line
**Google OAuth clients → Cloudflare deploy (R2 + Cerebras + DNS) → store enrollment + real signing → store listings/compliance → TestFlight/Play pilot → paywall → public launch.** The competition runs in parallel and, if won in September, funds Milestones 2–3.

# Founder TODO — everything Claude can't do

_The human-only work to get Holdclose to production + through the ACL Challenge.
Everything else (code, tests, drafting) Claude handles. Consolidated from
`ROADMAP_TO_PRODUCTION.md`, `SUBMISSION_TODO.md`, `OPERATOR_SETUP.md` on
2026-07-09. `[ ]` = open._

Legend: **DECISION** = a choice only you can make · **ACCOUNT/$** = signup, money,
or legal · **CONSOLE** = you run it, Claude gives exact steps · **PERSONAL** = your
info / real people.

---

## A. Accounts & ownership — consolidate under JCSV One LLC (do first)
- [ ] **GitHub** — create the JCSV org and **transfer the `holdclose` repo** to it (repo → Settings → Transfer). Tell Claude when done; he updates the git remote + docs. *(ACCOUNT)*
- [ ] **Claude subscription** — move billing to the JCSV Google account + JCSV bank. *(ACCOUNT/$)*
- [ ] **Google/GCP ownership** — from `jcsvonellc@gmail.com`, take Owner on GCP project 187697773608 (grant + accept). One identity for OAuth, Play, payout. *(ACCOUNT)*
- [ ] **Cloudflare billing** — confirm R2/Workers billing + payment method are on the LLC (account already under `jcsvonellc@gmail.com`). *(ACCOUNT/$)*
- [ ] **Publisher identity** — individual vs. JCSV One LLC entity (affects OAuth, store accounts, prize payout). *(DECISION)*

## B. Sign-in — Google OAuth (unblocks `AUTH=google` builds; ~5 min)
- [ ] **Create iOS + Android OAuth clients** for `com.holdclose.holdclose` (steps in `OPERATOR_SETUP.md §1`). **Paste the iOS client id to Claude** to wire it. *(CONSOLE)*

## C. Cloudflare production deploy
- [ ] **Enable R2** (dashboard → R2; blocked today with code 10042 until terms + payment method). *(CONSOLE/$)*
- [ ] Create buckets `holdclose-forum-media` + `holdclose-doc-blobs`. *(CONSOLE)*
- [ ] Set Worker secrets: `FORUM_JWT_SECRET`, `CLOUDFLARE_API_TOKEN`, `RESEND_API_KEY`. (No AI key — Workers AI is key-less.) *(CONSOLE)*
- [ ] `npm run deploy` + `wrangler d1 migrations apply FORUM_DB --remote`. *(CONSOLE)*
- [ ] **Point `holdclose.care` DNS at the Worker** (add the zone to Cloudflare, attach the custom domain). Required for the Terms/Privacy pages + invite links. *(CONSOLE)*
- [ ] After the AI migration deploys: **validate real inference** — chat quality + scan-extraction accuracy on Workers AI (can't be tested off the live account). *(DECISION/CONSOLE)*

## D. Store enrollment & signing (multi-week — start early)
- [ ] **Apple Developer Program** enrollment (org, JCSV One LLC / D-U-N-S 13-689-7602). *(ACCOUNT/$)*
- [ ] **Google Play Console** enrollment (org). *(ACCOUNT/$)*
- [ ] **Android release keystore** — generate with a secure password (Corretto-17 keytool) → `android/holdclose-release.keystore` + `android/key.properties`; **register its SHA-1 on the OAuth Android client** (steps in `OPERATOR_SETUP.md §4.2`). *(CONSOLE)*
- [ ] **Apple signing** — App ID `com.holdclose.holdclose`, distribution cert, provisioning profile. *(CONSOLE)*

## E. App Store (iOS) submission
- [ ] Create the app record in App Store Connect (name, category, subtitle). *(CONSOLE)*
- [ ] **App Privacy labels** — Claude drafts from the privacy policy; you review + submit. *(PERSONAL)*
- [ ] Age rating questionnaire; export-compliance declaration; content-rights. *(PERSONAL)*
- [ ] Point App Review at the working in-app "Delete account" (5.1.1(v)). *(PERSONAL)*
- [ ] Upload a real-signed build → TestFlight (internal → external pilot) → submit for review. *(CONSOLE)*

## F. Google Play submission
- [ ] Create the app; set up closed → open testing tracks (required before production). *(CONSOLE)*
- [ ] **Data safety form** (mirror the iOS labels). *(PERSONAL)*
- [ ] Content rating (IARC); target audience; ads declaration (none); public privacy URL `holdclose.care/privacy`. *(PERSONAL)*
- [ ] Upload AAB → promote internal → closed → open → production; enroll in Play App Signing. *(CONSOLE)*

## G. Product decisions — DECIDED + implemented (now need your side)
- [x] **At-rest DB encryption → SQLCipher** (built, `c488cf6`). → **you:** validate on device — `cd ios && pod install`, install a plaintext build with data, then this branch, confirm the data survived the auto-migration.
- [x] **Crash aggregation → both** (built, `bec54ed`). → **you:** stand up a self-hosted Sentry, add its `SENTRY_DSN` to release build defines.
- [~] **Pricing → free now, paywalled features later, always a free trial** (paywall machinery built, `0ab25e4`). → **you:** create the subscription products (price points + IDs) in App Store Connect + Play Console, and decide which features become premium (I then wire the gate).

## H. Business model (monetization phase)
- [ ] Affiliate program: tax/payout setup + terms. *(ACCOUNT/$)*
- [ ] (Pricing decision — see G.)

## I. Competition (ACL Challenge — HARD deadline: July 31, 2026, 5 pm ET)
**Cover page + attestations**
- [ ] Legal name, email, phone; **U.S. citizen/PR attestation**; Track 1; alternate contact (or "N/A, solo"). *(PERSONAL)*
- [ ] $0-liability attestation; IP-license + warranties agreement. *(PERSONAL)*
- [ ] (Optional) SAM.gov UEI for the LLC — expedites payout. *(ACCOUNT)*
- [ ] The **ACL clarification email is NOT required** — resolved this session: no real eligibility conflict. Skip unless you want written comfort. *(DECISION — likely skip)*

**Bio & lived experience (§1/§2)**
- [ ] Founder name everywhere it appears. Confirm the bio: VBMS/VA "ten years", veteran, 100%-disabled-veteran father caregiving — accurate + OK to publish. *(PERSONAL)*
- [ ] Confirm the dementia-grandfather detail if keeping §5. *(PERSONAL)*

**User-centered evidence (scores ~zero without this)**
- [ ] Fill `FEEDBACK_LOG.md` — real tester quotes, care situations, **consent to cite**, and what the product changed. *(PERSONAL)*
- [ ] The real tester `[N]` + pilot-cohort size/duration numbers. *(PERSONAL)*
- [ ] 1–2 more concrete feedback-driven changes (beyond removing the Behavior Decoder). *(PERSONAL)*
- [ ] Recruit 3–5 more caregivers (incl. ≥1 dementia caregiver if keeping §5) via `recruiting_kit.md`. *(PERSONAL)*
- [ ] **Do NOT fabricate** any quote/metric/letter — all must trace to a real, consenting person.

**Partnerships / appendix**
- [ ] Send `outreach_email.md` (CAN, an Area Agency on Aging, an Alzheimer's chapter, a clinician); collect 2–3 letters of support. *(PERSONAL)*
- [ ] Secure or soften the §2 "advisor commitments". *(PERSONAL)*

**Decisions & final assembly**
- [ ] §5 dementia meritorious ($50K): **keep-with-evidence or drop** (recommendation in `SUBMISSION_TODO.md`). *(DECISION)*
- [ ] Pricing commitment for §4 Principle 7. *(DECISION — see G)*
- [ ] **Final 508-compliant assembly** — merge cover + §1–§5 + appendix → one PDF/Word, submit one email to CaregiverAI@acl.hhs.gov. *(Claude assembles the draft; you do the final review + send.)*

---

### If you only do five things this week
1. **Google OAuth clients** (B) — unblocks sign-in in one sitting.
2. **Enable R2 + deploy the backend** (C) — makes everything real.
3. **Start Apple + Play org enrollment** (D) — the long pole; nothing ships without it.
4. **Fill the tester evidence + bio** (I) — the competition's weakest section, deadline-driven.
5. **Send the outreach email** (I) — letters take time to come back.

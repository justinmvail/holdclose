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
- [x] **Publisher identity → JCSV One LLC** (decided 2026-07-10). Entity everywhere: an **entity** ACL application (prize paid to the LLC), **organization** Apple + Play accounts, GCP project + GitHub owned by `jcsvonellc@gmail.com`. Cover page team/entity = "Juno Code Studio (JCSV One LLC)".

## B. Sign-in — Google OAuth (unblocks `AUTH=google` builds; ~5 min)
- [ ] **Create iOS + Android OAuth clients** for `com.holdclose.holdclose` (steps in `OPERATOR_SETUP.md §1`). **Paste the iOS client id to Claude** to wire it. *(CONSOLE)*

## C. Cloudflare production deploy
> **Dev environment is LIVE (2026-07-10).** The backend is deployed to the
> jcsvonellc Cloudflare account (ID `1d05533f…c5ea`) as the `dev` wrangler
> environment → **`holdclose-forum-dev.jcsvonellc.workers.dev`**. Live +
> verified: Worker, D1 `holdclose-forum-dev` (9 migrations), JWT auth, and the
> **AI coach on native Workers AI** (chat streamed a real Llama-3.3-70b reply
> end-to-end). Deploy = `wrangler deploy --env dev`. R2 uploads now wired too
> (buckets `holdclose-forum-media-dev` + `holdclose-doc-blobs-dev` bound as
> FORUM_MEDIA/DOC_BLOBS; public media serving still needs a real R2_PUBLIC_URL).
> Not yet on dev: scan/vision extraction (still REST-token). Point the app at
> it via `FORUM_API_URL=https://holdclose-forum-dev.jcsvonellc.workers.dev`.
> The items below are the remaining **production** (holdclose.care) deploy.
- [x] **Enable R2** — done 2026-07-10 (account-wide). Dev buckets `holdclose-forum-media-dev` + `holdclose-doc-blobs-dev` created + bound. Prod buckets (`holdclose-forum-media` / `holdclose-doc-blobs`) still to create at prod deploy. *(CONSOLE/$)*
- [ ] Create buckets `holdclose-forum-media` + `holdclose-doc-blobs`. *(CONSOLE)*
- [ ] Set Worker secrets: `FORUM_JWT_SECRET`, `CLOUDFLARE_API_TOKEN`, `RESEND_API_KEY`. (No AI key — Workers AI is key-less.) *(CONSOLE)*
- [ ] `npm run deploy` + `wrangler d1 migrations apply FORUM_DB --remote`. *(CONSOLE)*
- [ ] **Point `holdclose.care` DNS at the Worker** (add the zone to Cloudflare, attach the custom domain). Required for the Terms/Privacy pages + invite links. *(CONSOLE)*
- [~] **Validate real inference** — ✅ chat verified end-to-end on Workers AI (dev env, native binding, real Llama-3.3-70b stream). Still to validate: scan/vision extraction (needs the native vision-input format wired + a real label photo). *(DECISION/CONSOLE)*

## D. Store enrollment & signing (multi-week — start early)
- [~] **Apple Developer Program** enrollment (org, JCSV One LLC / D-U-N-S 13-689-7602). Started 2026-07-10; **blocked on Apple throttles after many attempts — don't fight it, resume next day.** Restart notes:
  - **Use the EXISTING Apple Account — do NOT create a new one.** `jcsvonellc@gmail.com` is an alias on Justin's personal `justinmichaelvail@icloud.com` (same account). A new account isn't needed: the org identity = the D-U-N-S, not the holder email. New-account creation kept failing "Your account cannot be created at this time" on BOTH Wi-Fi and cellular → not an IP throttle alone; likely the VoIP phone number and/or an anti-fraud flag from repeated tries.
  - Existing-account enrollment hit "max attempts / contact us" lock (from dropped email codes before forwarding was live). Auto-resets ~24h, or click **contact us** to reset.
  - ✅ **Work email `admin@junocode.studio`** set up via Cloudflare Email Routing → forwards to `jcsvonellc@gmail.com` (destination Verified, routing rule Active). Apple's verify email now Forwards (was Dropped). So the email step passes first try next time — enter the code ONCE, no resends.
  - For any phone verification, use a **real mobile number** — the Google Voice number (843) 642-8302 is VoIP and Apple may be rejecting it. *(ACCOUNT/$)*
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
- [~] **Play org account "Juno Code Studio"** — Organization account, ID 5351202474101549368. $25 + org creation done; org accounts SKIP the closed-testing gate. Verification progress (2026-07-10):
  - ✅ **Org registration** — uploaded the IRS **CP 575** for JCSV One LLC (in `~/Downloads/EIN Certificate.pdf`; backups: SC Certificate of Existence + certified Articles, same folder).
  - ✅ **Website** — verified `junocode.studio` (the live JCSV/Juno Code Studio site, on Cloudflare — NOT holdclose.care, so it was never blocked on the DNS work) via **Google Search Console** ownership (DNS TXT).
  - ⏳ **Identity** — docs uploaded; Google reviewing (~few days); account owner gets an email when done. NOTHING to do until then.
  - 🔒 **Phone** — auto-unlocks after identity approves; then enter a number + code.
  - TODO once identity clears: add `jcsvonellc@gmail.com` under Users & permissions if it's not the owner.
- [ ] Create the Holdclose app (no closed-testing period needed on an org account). *(CONSOLE)*
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

### Order of operations (2026-07-10)

Two parallel tracks: **Competition** (hard deadline July 31, 2026, 5pm ET) and
**Production** (no deadline, but store enrollment has weeks of lead time). Two
things must start TODAY because they wait on *other people*, not you: store org
enrollment and competition letters/tester evidence.

**Wave 1 — today (start everything with external lead time):**
1. ✅ Publisher = JCSV One LLC (done).
2. Start **Apple Developer Program + Google Play Console org enrollment** (JCSV One LLC / D-U-N-S 13-689-7602) — longest pole; multi-week approval.
3. **Send the competition outreach emails + start recruiting testers** — letters + real quotes come from others on their timeline.
4. **Consolidate GitHub + GCP under JCSV** (transfer repo; take Owner on GCP 187697773608) — so the OAuth clients you make next are already under the LLC.

**Wave 2 — this week (quick unblocks + your content):**
5. **Create the Google OAuth clients** → paste Claude the iOS id → sign-in works (also unblocks AUTH=google + billing testing).
6. **Confirm bio + cover-page attestations + the two decisions** (§5 dementia keep/drop, the §4 pricing sentence).

**Wave 3 — next (make the backend real; no deadline pressure):**
7. **Cloudflare deploy** — enable R2, secrets (incl. `CF_AI_API_TOKEN`), `npm run deploy`, migrate D1, point `holdclose.care` DNS at the Worker.
8. **Validate on the live deploy** — chat/scan quality on Workers AI + the delete-account round-trip.

**Wave 4 — rolling, before ~July 28:**
9. Feed Claude tester evidence as it lands (real, consented).
10. **~July 28–30: Claude assembles the final 508 PDF; you review + send** to CaregiverAI@acl.hhs.gov before **July 31, 5pm ET** ← the one true deadline.

**Wave 5 — when enrollment approves (likely AFTER July 31, and that's fine):**
11. Release keystore + Apple signing (keystore SHA-1 needs the OAuth Android client from step 5).
12. App Store + Play listings, privacy/data-safety forms, upload, review → pilot.
13. Monetization tail: Sentry DSN, store subscription products, affiliate setup.

**Key:** the competition submission does NOT depend on the store deploy — the
app already runs on testers' phones (that's the TRL-3 "deployment readiness").
Don't let the production track crowd out the July-31 work.

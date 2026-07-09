# Holdclose — production & competition readiness audit

_Generated 2026-07-08. 15-agent audit (security, production, UX, responsible-AI
principles, packet) with adversarial verification of every high/critical
finding. Scored against the ACL Caregiver AI Challenge Track 1 judging criteria
and 7 AI Principles (Phase 1 narrative due July 31, 2026)._

Every high/critical finding below **survived** an independent refutation pass.
Severities are the verifier's adjusted values.

---

## FIXED already (this session)

- **CRITICAL — remote arbitrary file read via the shim.** The funnel-exposed
  `claude_shim.py` passed client prompt text to `claude --print`, which expands
  `@path` mentions into file contents; a request could exfiltrate
  `~/.claude/.credentials.json` or `backend/.dev.vars` (the JWT signing secret)
  in the reply. Reproduced live, fixed (fullwidth-`@` neutralization of client
  text), verified with a canary, live shim reloaded. Commit `c08901e`.

---

## TIER 1 — must-fix before wider distribution / submission

| # | Sev | Finding | Where | Fix |
|---|-----|---------|-------|-----|
| 1 | CRIT | **Android reminders can NEVER fire** — required manifest receivers/permissions missing; the scheduling exception is silently swallowed, so forms report success while no reminder is set. Core feature (med/appointment reminders) dead on all Android. | `local_notifications_provider.dart:115-148`; `AndroidManifest.xml` | Add `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` + the `flutter_local_notifications` receivers; surface scheduling failures instead of swallowing. |
| 2 | CRIT | **"Delete account" deletes nothing server-side** — only wipes the local token; profile, posts, circle data, synced patients + R2 blobs persist forever. Privacy Principle 1 + Apple 5.1.1(v) store blocker. | `auth_provider.dart:352-355,528`; no Worker route | Add `DELETE /profiles/me` cascading across D1 + R2; wire the Settings button to it. |
| 3 | HIGH | **Chat med/appointment mutations auto-execute without the confirm card** — only delete/cancel/delete_task are gated; `update_medication` (dosage!), `update_appointment` (time), `log_dose`, `add_medication` run instantly, voice included. A hallucinated/mistranscribed "10mg→100mg" writes silently. | `chat_service.dart:885-889`; `chat_actions.dart:304-322,441-458` | Gate mutations of existing meds/appointments (or dosage/time changes) behind the confirm card; keep instant only for additive low-stakes writes. |
| 4 | HIGH | **Coach action failures are swallowed while the AI says "logged it"** — `catch (_)` drops executor errors; the assistant claims success when nothing saved. A circle member seeing no dose may re-administer. | `chat_service.dart:953-963` | Propagate failures; have the reply reflect actual write result; log for triage. |
| 5 | HIGH | **Android release builds sign with the DEBUG keystore** — store blocker; every debug-signed build forces uninstall + local PHI loss on the next real-signed one. | `android/app/build.gradle.kts:67-69` | Create a release keystore, wire `signingConfigs.release`, register its SHA-1 on the OAuth Android client. |
| 6 | HIGH | **No crash reporting** — production crashes invisible; release builds also lack the manual report button, so zero failure channel. | no Sentry/Crashlytics anywhere | Add a privacy-respecting crash reporter (self-hosted Sentry or Sentry with PII scrubbing; keep the no-vendor-name rule in UI). |

## TIER 2 — responsible-AI & safety (directly scored by judges)

| # | Sev | Finding | Where | Fix |
|---|-----|---------|-------|-----|
| 7 | HIGH | **No AI surface flags uncertainty/weak data** — extraction prompts turn "unsure" into blank fields; judging explicitly wants "flag weak-data results" (Principle 2). | `prescription_extraction_prompt.dart:22-23` etc. | Add an `uncertain:[...]` array to extraction schemas; render amber "check this" in the review screens; add an uncertainty clause to the chat prompt. Enables the Smart-40 HITL flags too. |
| 8 | HIGH | **Chat/voice crisis handling is prompt-only** — the deterministic keyword watchdog exists for the forum but not the coach; if the model fails/jailbreaks, nothing catches "I want to kill myself". | `chat_system_prompt.dart:88-98`; watchdog only in `backend/` | Port CRISIS_KEYWORDS to Dart, scan outgoing chat/voice messages code-side, pin a trusted (non-LLM) 988 crisis card on match. |
| 9 | HIGH | **Voice mode writes med/dose data with confirmation explicitly suspended, no undo** — 2.6s transient flash then gone. | `chat_system_prompt.dart:245-251`; `tab_scaffold.dart:392-397` | Route med-mutating voice actions through the confirm card; keep low-friction only for journal/health/task; add undo. |
| 10 | MED | **Prompt-injection hardening applied unevenly** — the "catch me up" recap, visit-prep, and insurance-appeal prompts interpolate circle-synced second-party text raw (no `sanitizeForPrompt`, no delimiter, no data-not-instructions rule) — exactly the surfaces added after the `chat_context_builder` hardening. | `llm_provider.dart:257-269`; `visit_prep_service.dart:84-89`; `insurance_appeal_service.dart:107-125` | Route those fields through `sanitizeForPrompt` + delimiter tags; add the data-not-instructions clause to each system prompt. |
| 11 | MED | **Production chat forwards PHI to Cerebras; privacy policy omits the subprocessor.** | `backend/src/routes/chat.ts:159-181`; `legal.ts` | Add a subprocessors clause; minimize PHI in the grounding snapshot (first-name-only, drop DOB where not needed). |

## TIER 3 — UX / usability / accessibility (§3 "prevents user error", "easy to use")

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 12 | HIGH | **Primary CTA fails WCAG contrast** — white on salmon `#C97458` = 3.43:1 (needs 4.5:1); dark mode hardcodes white labels. A judge with a contrast checker catches this on any screenshot. | Use `#B05C40` (4.72:1) for filled-button bg; stop hardcoding `Colors.white`, use `onSecondary`. |
| 13 | HIGH | **In-app font-size setting REPLACES OS Dynamic Type** (caps at 1.35×) — older caregivers who enlarged text OS-wide get none of it. | Compose: `base.textScaler.scale(...) * fontSize.scale`, clamped. |
| 14 | HIGH | **First-run Home is a dead end** — "No upcoming items." with no guidance; the promised quick-action FAB doesn't exist. First post-onboarding screen a judge sees. | Instructive empty state with 2-3 CTAs (Add medication / Scan prescription / Ask the coach). |
| 15 | HIGH | **"Catch me up" recap is the one AI surface with no AI label or accuracy caveat.** | Add a trusted caption: "Summarized by your coach from your recent log — check anything important." |
| 16 | MED | **Dementia-specific copy at first-touch** (chat empty-state examples, seeded guidelines) contradicts the general-purpose positioning. | Broaden the example prompts to span care situations. |
| 17 | MED | **Delete dialog promises "you can recover it later" but no recovery UI exists.** | Add "Recently deleted" restore (tombstone already supports it) or fix the copy + add Undo. |
| 18 | MED | **Sub-44px hit targets + missing button semantics** on breadcrumbs, chat retry, voice-cancel. | Wrap in `Semantics(button:true)`, 44px min. |
| 19 | LOW | Jargon ("@username/QR/handle", "NPI") in empty states with no CTA; insurance-appeal validates via SnackBar not inline errors. | Plain-language rewrites + `TextFormField` validators. |

## TIER 4 — data-protection hardening

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 20 | MED | **iOS backups sweep the PHI DB, scans, voice notes, feedback outbox into iCloud** — Android sets `allowBackup=false` for exactly this reason; iOS has no parity. | RESOLVED (at-rest): the local DB is now encrypted with **SQLCipher**, key in the device keychain/keystore, so a swept-up copy is ciphertext. iOS files are also backup-excluded (`NSURLIsExcludedFromBackupKey`) + `NSFileProtectionComplete` as defense in depth. |
| 21 | MED | **SHIM_TOKEN baked into sideloaded binaries** guards the operator's Claude subscription; extractable, no per-tester attribution, no rate limiting. | Per-tester tokens (rotation list already supports it) + shim rate limiting; longer-term move alpha to the quota-capped Worker `/chat`. |
| 22 | MED | **Data portability is one-way** — `importInto` exists but is never wired to UI; export omits coach chat history. | Add a "Restore from backup" Settings row; add chat sections to the export. |
| 23 | LOW | Feedback reports default both consent toggles ON (PHI screenshot + 300-line log). | Default the screenshot toggle OFF, or show a redaction preview. |

---

## COMPETITION PACKET — submission-readiness (23 days out)

**Falsifiable overclaims (fix the narrative OR build the feature):**
- §1/§3/§4 claim "**every** action that changes care data routes through a
  confirmation card" — false (only 3 destructive actions; voice suspends it).
  Reword truthfully, or build Tier-1 #3 + Tier-2 #9 and keep the claim.
- §1/§2/§3/§4 claim a built "**uncertainty/escalation path**" — doesn't exist
  (Tier-2 #7). Build it (also unlocks the Smart-40 HITL flags) or cut the claim.
- LLM-vendor claims contradict each other ("currently Claude" vs "[Cerebras]")
  and the shipped path (gpt-oss-120b via Cerebras). Pick one true sentence.
- §4 claims present-tense red-teaming; **no Data Output Logs exist**
  (no Smart-40, no Protocol-9-Delta, no F1/accuracy).

**Missing required elements:**
- **Cover page + ≤250-word Abstract** — not drafted (GAP_ANALYSIS wrongly marks
  it ✅). Hard requirement; missing = disqualifying.
- **User-centered evidence** — FEEDBACK_LOG is 100% template; the flagship
  "testers drove the decoder removal" claim has no citable documentation.
  Judging criterion 2 currently scores ~zero.
- **Partnerships / letters of support** — none; the outreach + ACL
  eligibility-clarification emails still have `[placeholders]` and appear unsent
  (their own July-15 reply-by is days away). Criterion 6 scores zero; the
  eligibility question (contractor status, $0 liability) is an existential risk.
- **§5 dementia meritorious (+$50K)** under-evidenced after the de-dementia
  pivot — needs 1-2 dementia caregivers in testing + dementia Smart-40 scenarios,
  or drop the claim.
- Encryption brackets must be filled **truthfully**. SQLCipher is now
  adopted, so the local DB IS encrypted at rest (key in the device
  keychain/keystore) — claim that alongside OS device encryption + backups
  off (Android `allowBackup=false`, iOS backup-excluded) and TLS in transit.

**Cheapest high-value wins:** the Smart-40 log (28 standard + 4 stress + 4
boundary/safety cycles, ≥2 HITL flags) + the Protocol-9-Delta refusal probe run
through the real stack — the single strongest differentiator for a solo entrant
with a genuinely working app, and it forces #7/#8 to be real.

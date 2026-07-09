# Submission TODO — remaining placeholders & decisions

Inventory of every `[BRACKET]` / placeholder still open across the packet, plus
the merge-blocking decisions. Split into what **only the founder** can supply and
what is **already drafted** (needs at most a light confirm). Generated after the
2026-07-08 rewrite pass that fixed the falsifiable overclaims and filled the
encryption/vendor brackets.

Legend: 👤 = **[FOUNDER-only]** (private input, real people, sending/signing) ·
✅ = **[draftable / done this session]** · ⚠️ = drafted but needs a real number or
a one-line confirm.

---

## 👤 [FOUNDER-only] — nobody but the founder can supply these

### Contact & attestations (cover page + rules)
- [ ] **Primary contact:** full legal name, email, phone (`00_cover_abstract.md`).
- [ ] **U.S. citizen / permanent-resident attestation** — check the box, state
      status (`00_cover_abstract.md`).
- [ ] **Alternate contact** — name/email/phone, or confirm "N/A, solo entrant."
- [ ] **Liability = $0 attestation** — sign the $0-financial-responsibility +
      federal-indemnification language (confirm exact wording via the ACL email).
- [ ] **IP license + warranties** — agree (grant ACL the name/title/summary
      license; attest sole authorship / non-infringing).
- [ ] **SAM.gov UEI** (encouraged, expedites payout) — register the LLC and
      obtain a UEI.

### Bio & lived-experience specifics (§1 End-User Input, §2 Team & Roles)
- [ ] **Founder name** everywhere it appears (`02_section2.md` "[Your Name]",
      cover, emails).
- [ ] **Bio sketch confirm** — verify the VBMS "ten years" figure, the
      Benefitfocus/health-benefits detail, and the "currently a W-2 contractor
      on a VA contract / being laid off" framing (also load-bearing for the ACL
      eligibility email). Experience + affiliation + role is a §2 requirement.
- [ ] **Family-experience line** — confirm the dementia grandfather detail for
      §5 and the father / 100%-disabled-veteran caregiving detail for §1/§2 are
      accurate and OK to state publicly.

### User-centered evidence (§1 End-User Input; `FEEDBACK_LOG.md`)
- [ ] **Tester count `[N]`** — the real number of family-caregiver testers
      (`01_section1.md` line 123; `02_section2.md` pilot cohort `[N]`).
- [ ] **Tester blocks** — fill `FEEDBACK_LOG.md` (12 template blanks): each
      tester's care situation, what they used, what they said, **what the product
      changed because of it**, and **consent to cite / write a letter**.
- [ ] **1–2 more concrete feedback-driven changes** beyond the Behavior-Decoder
      removal (`01_section1.md` line 127) — must be true, drawn from the log.
- [ ] **Recruit 3–5 additional caregivers** for July structured sessions
      (`recruiting_kit.md`) and document them — the User-Centered criterion
      currently scores near zero without this.
- [ ] **Do NOT fabricate** any quote, metric, or letter — all must trace to a
      real tester who consented.

### Partnerships & letters of support (Appendix; Partnerships criterion)
- [ ] **Send `outreach_email.md`** to CAN, an Area Agency on Aging, an
      Alzheimer's chapter, and a geriatric clinician — reply-by July 15.
- [ ] **Collect 2–3 letters of support** for the appendix.
- [ ] **Advisor commitments** referenced in §2 "Planned additions" — secure or
      soften if none land.

### Emails to actually send
- [ ] **Send `acl_clarification_email.md`** to CaregiverAI@acl.hhs.gov (fill the
      signature block) and act on the contractor-eligibility + $0-liability reply.

### Pilot / business specifics
- [ ] **Pilot cohort size + duration** — `[N]` caregivers, `[8–12]` weeks
      (`02_section2.md`).
- [ ] **Pricing commitment** — §4 Principle 7 (`04_section4.md`): state the free
      tier / low-cost-subscription commitment in transparent terms.

---

## ✅ [draftable / handled this session]

- [x] **Cover page + ≤250-word Abstract** — `00_cover_abstract.md` created;
      Abstract drafted from known facts at **248 words** (recount if edited).
      (GAP_ANALYSIS previously mismarked this ✅ before it existed; now real.)
- [x] **"Every care-data change confirms" claim** — reworded in §1/§3/§4 to the
      post-fix truth: **every AI action that changes existing care data, in chat
      *or* voice, routes through the confirmation card.**
- [x] **"Built uncertainty/escalation path" claim** — reworded to the post-fix
      truth: an **uncertainty clause** in the chat prompt, **weak-data flagging**
      in the scan-to-import extractors, and a **code-side (non-LLM) crisis
      watchdog** on chat/voice now exist.
- [x] **LLM-vendor contradiction** ("currently Claude" vs "[Cerebras]") — replaced
      everywhere with one truthful sentence: **model-agnostic; currently the
      open-weight gpt-oss-120b served via Cerebras through a quota-enforcing
      backend.** No vendor/model named in any user-facing app string (this is a
      narrative-only mention, which the packet permits).
- [x] **Encryption brackets** — filled truthfully in §2 and §4: **TLS in
      transit; OS device encryption on-device; OS backups disabled (Android
      `allowBackup=false`, iOS files excluded from backup); server data on
      Cloudflare D1/R2.** Deliberately does **NOT** claim at-rest DB encryption
      (the local SQLite DB is plaintext PHI).
- [x] **HIPAA stance** — stated: consumer tool used by families, **not a HIPAA
      covered entity**, built privacy-forward.
- [x] **§2 deployment-readiness overclaim** — dropped the false "Play Open
      Testing / TestFlight install links" language; reworded to sideloaded signed
      builds today + store release as a submission-and-approval (not engineering)
      step.
- [x] **§4 present-tense red-teaming** — softened to a planned red-team + Data
      Output Logs (none exist yet).
- [x] **§3 accessibility bracket** — filled: text-size control layered on OS
      Dynamic Type, simple flows, warm high-contrast palette, WCAG-AA hardening
      in progress.
- [x] **§3 interoperability bracket** — split into shipped-today (care-summary
      PDF, NPI find-a-provider) vs. planned (EMR/assistive-device interop).
- [x] **TRL descriptor brackets** (§1/§2 "[Flutter; …]") — converted to confirmed
      prose (Flutter, iOS+Android, suites green, Cloudflare Worker backend).
- [x] **Emails drafted to the founder-signature line** — `outreach_email.md` and
      `acl_clarification_email.md` are ready to send once the signature/contact
      brackets are filled; the ACL email crisply asks the contractor-eligibility
      and $0-liability questions.

### ⚠️ Still needs a real number, not writing
- [ ] The `[N]` tester/pilot counts above — writing is done, the number is not.

---

## Optional, high-value (🤖 draftable, not yet done)
- [ ] **Data Output Logs** — run the coach through the "Smart 40" (28 standard +
      4 stress + 4 boundary/safety cycles, ≥2 HITL-uncertainty flags) and the
      "Protocol 9-Delta" refusal probe through the real stack. Strongest TRL
      differentiator for a solo entrant; forces the uncertainty + crisis-watchdog
      work to be exercised end-to-end. Separate document, no page limit.
- [ ] **Final 508-compliant assembly** — merge cover + §1–§5 + appendix into one
      PDF/Word, ≥11pt font, 1-inch margins, page numbers on the narrative.

---

## §5 Meritorious (dementia focus area) — recommendation

**Question:** with the product having pivoted from dementia-specific to
general-purpose caregiving, is the +$50K dementia meritorious claim in
`05_section5.md` still defensible?

**Recommendation: KEEP the claim, but only if it is evidence-backed — otherwise
DROP it.** The claim is honest in spirit (dementia *is* where the product
started, the founder's grandfather lived with dementia, and the pattern
detector / care circle / emergency card genuinely serve dementia care). But the
DEEP_DIVE_AUDIT is right that after the de-dementia pivot it is currently
**under-evidenced**, and an unsupported meritorious claim can read as
opportunistic to a judge and undercut the credibility of the whole packet.

Make it earn its place by adding, this cycle, **at least one of**:
1. **≥1 dementia caregiver in the documented testing** (the grandfather
   experience is lived-context, not tester evidence) — a real dementia-caregiver
   feedback block in `FEEDBACK_LOG.md`, cited in §5.
2. **Dementia-specific safety scenarios** in the optional Data Output Logs
   (e.g. wandering, sundowning, agitation prompts) showing the coach responds and
   escalates appropriately.

If **neither** lands before July 31, **drop §5** and reclaim the page budget —
the general-purpose narrative stands strongly on its own, and a thin optional
claim is worse than no claim. Do not manufacture dementia-tester evidence to keep
it (👤 must be real).

**Watch-out:** §5 currently uses dementia-behavior framing ("agitation,
wandering, repetition, sundowning ... helps caregivers understand and respond").
Keep this scoped to *coaching the caregiver*, never diagnosing or interpreting
the loved one's condition — consistent with the app's non-diagnostic guardrail.
The current §5 wording is on the right side of that line; preserve it if edited.

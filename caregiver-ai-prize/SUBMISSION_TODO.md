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

## ✅ [handled in the 2026-07-09 evidence pass]

- [x] **CAN 2026 survey woven into §1 and §4** — §1 Understanding-of-Need now
      leads with the real numbers (63M caregivers, avg 51, 27 hrs/wk, ~$600B; 37%
      ≥11 hrs/wk on coordination; meds/refills 50%, scheduling 46%; ~1-in-3
      "fragmented"); §1 Supporting Research maps the six CAN AI use cases and the
      delegation wish-list **1:1** onto shipped Holdclose features (table); §4
      Principle 7 cites the top adoption barriers (cost 43%, trust 42%, privacy
      40%) and answers each. Cited as *Caregiver Action Network, 2026 Caregiver
      Tech Insights Survey (n = 272)*.
- [x] **Net-Time-Saved estimate** — added to §2 as a **data-backed estimate**
      (CAN 11+ hrs/wk coordination × Holdclose's coverage of the dominant tasks →
      ~1.5–3 hrs/wk returned), explicitly framed as an estimate to be *measured*
      in Phase 2 (no invented hard number).
- [x] **Actionable Workflow diagram** — added to §3: Input → AI Analysis →
      Caregiver Action → Result (photograph a prescription → extraction with
      uncertainty flags → caregiver reviews/approves → meds + dose windows
      created). ASCII diagram, human-in-the-loop last step.
- [x] **Bench-metric honest framing** — added to §2: the **41/41 guardrail
      pass-rate** (`DATA_OUTPUT_LOGS.md`) is the measurable safety result today;
      **F1/precision/recall/accuracy** for the scan-extraction classifiers stated
      as a **Phase-2 measurement plan on a labeled corpus** (not fabricated).
- [x] **AI-vendor update → Cloudflare Workers AI** — swept `01_section1.md`
      (×4), `04_section4.md` (Principles 1 + 7), `README.md`, and the production-
      path claims in `DATA_OUTPUT_LOGS.md`. Every mention now reads *model-
      agnostic; AI runs on Cloudflare Workers AI (an open-weight model on our own
      cloud infrastructure), so the loved one's data never goes to a separate AI
      vendor.* (Cerebras / gpt-oss retired from the packet narrative. The
      `DEEP_DIVE_AUDIT.md` audit-log rows are left intact as a historical record;
      its item-11 "PHI forwarded to Cerebras" finding is now resolved by this
      move.) Leaned into the privacy win in §4 Principle 1.
- [x] **Consolidated `NARRATIVE.md`** — cover + abstract + §1–§5 assembled in
      official order with the exact section headings, `[FOUNDER: …]` placeholders
      intact. ~5,190 words; renders to **13 pp at pandoc-default styling** →
      comfortably ≤15 pp once set at 11pt / 1-inch margins.
- [x] **PDF conversion done (pandoc 3.9.0.2 + weasyprint)** — `NARRATIVE.pdf`
      and `DATA_OUTPUT_LOGS.pdf` generated. Note: pandoc had **no LaTeX engine**
      on this machine, so the PDFs were built via the `--pdf-engine=weasyprint`
      HTML route. These are **preview/print-ready PDFs**; the **final
      508-compliant PDF/Word** (tagged, 11pt body, 1-inch margins, page numbers on
      the narrative) remains a **👤 founder step** — see below.

## ✅ [draftable / handled the 2026-07-08 session]

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
      everywhere with one truthful sentence. **(Superseded 2026-07-09:** the vendor
      sentence is now *model-agnostic; AI runs on Cloudflare Workers AI, an
      open-weight model on our own cloud infrastructure, so the loved one's data
      never goes to a separate AI vendor* — see the 2026-07-09 pass above.) No
      vendor/model named in any user-facing app string (this is a narrative-only
      mention, which the packet permits).
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

## Optional, high-value
- [x] **Data Output Logs** — DONE (`DATA_OUTPUT_LOGS.md`): 41 cycles through the
      real chat stack (32 standard incl. 2 thin-data HITL flags, 4 stress, 5
      boundary/safety + the Protocol-9-Delta probe). **41/41 guardrails held** —
      dosing/diagnosis/crisis/injection/unknown-protocol all correctly refused,
      confirm-card gating verified, code-side crisis watchdog covered by a Dart
      test. Methodology is honest that replies came from the dev `claude`-CLI
      path (production is gpt-oss-120b via Cerebras) and the structural guardrails
      are model-independent. Cited in §2 and §4.
- [x] **Narrative assembled** — `NARRATIVE.md` (cover + abstract + §1–§5 in
      official order) + preview `NARRATIVE.pdf` / `DATA_OUTPUT_LOGS.pdf` generated
      this pass (pandoc + weasyprint; no LaTeX on this machine).
- [ ] 👤 **Final 508-compliant conversion** — take `NARRATIVE.md` (fill the
      remaining `[FOUNDER: …]` + `[N]` brackets first) to a **tagged, 508-compliant
      PDF or Word**: ≥11pt body (≥9pt tables), 1-inch margins, page numbers on the
      narrative, no gov logos. The weasyprint preview PDFs are **not** guaranteed
      508-tagged — do the accessible conversion in Word or an accessibility-aware
      PDF tool as the last step, once the founder-only content above is filled.

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

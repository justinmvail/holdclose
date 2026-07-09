# Section 2 — Implementation Approach

> Draft. Official sub-headings. This is our STRONGEST section — a built, tested
> app makes "deployment readiness" real. `[BRACKETS]` = fill/verify.

## Deployment Readiness

Holdclose is **already built, tested, and running on device** — a Flutter app on
iOS and Android, with unit, widget, golden, and end-to-end integration suites
green and a deployed Cloudflare Worker backend for care-circle sync. Unlike
concept submissions, Holdclose is **installable and in the hands of testers
today**: signed builds are sideloaded to physical iOS and Android devices, and
the app has a live product presence at **holdclose.care**. Reviewers can see a
**real, working product — not a concept.** Public app-store release is a
submission-and-approval step, not further development — the remaining gate is
enrolling the publishing organization and completing store review, which is
Phase-2 operational work rather than engineering. This materially de-risks Phases
2 and 3: the build is done; the work ahead is validation, refinement, and reach.

## Implementation, Testing & Evaluation Strategy

- **Now–July 2026:** structured caregiver feedback sessions (existing
  family-caregiver testers + additional caregivers recruited from caregiver
  communities); refine based on what they tell us.
- **Phase 2 (if advanced):** TestFlight → App Store pilot with a cohort of
  [N] family caregivers over [8–12] weeks, instrumented for the metrics below;
  weekly iteration on feedback; safety review of AI-coach interactions.
- **Phase 3:** broaden distribution and establish sustainability (affordable
  pricing and/or caregiver-org partnerships) so the tool outlasts the grant.

## Timeline & Milestones

| When | Milestone |
|---|---|
| Now–Jul 2026 | Caregiver co-design sessions; refine; secure partner input |
| Sep 2026 | (If Phase 1 win) finalize App Store release; recruit pilot cohort |
| Phase 2 (2026–27) | Run instrumented pilot; collect performance + safety data; iterate |
| Phase 3 | Scale reach; establish affordable, sustainable model |

## Team & Roles

**[FOUNDER: your name] — Founder & Developer.** A **U.S. Air Force veteran** with over a
decade building and supporting federal health and benefits systems — including
**ten years on the Veterans Benefits Management System (VBMS)** and prior work
in health-benefits software (Benefitfocus). He built Holdclose end-to-end:
product design, the Flutter iOS/Android app, the server backend, and the AI
integration. His motivation is personal — he has repeatedly cared for his
father, a **100% disabled veteran** — and he built the assistant he wished he'd
had. This combination of **deep VA/health-systems expertise and lived caregiving
experience** is a rare fit for building responsibly at the intersection of aging,
disability, and veteran care. **Planned additions:** caregiver and clinical
advisors secured through partnerships (see letters of support, Appendix) to
strengthen co-design and real-world validation in Phases 2–3.

## Performance Metrics

- **Caregiver burden** — validated instrument (e.g., Zarit Burden Interview,
  short form) measured pre/post pilot.
- **Time saved** — reduction in time to log care via voice vs. manual entry
  (instrumented + self-reported).
- **Engagement & retention** — active use, return rate, task completion.
- **AI coach usefulness** — caregiver helpfulness ratings; share of coach
  interactions the caregiver acts on.
- **Safety** — rate of uncertainty-flag/escalation events; **target: zero
  unsafe medical directives** (adjudicated review).
- **Medication tracking** — consistency of dose logging over time.

## Net Time Saved (data-backed estimate)

ACL's Technology Readiness Guide asks for an estimate of the **hours returned to
the caregiver per week**. We build one from the Challenge judging partner's own
data rather than an invented figure. In the Caregiver Action Network 2026
Caregiver Tech Insights Survey (n = 272), **37% of caregivers spend 11 or more
hours a week on care coordination alone**, and the coordination burden
concentrates in four tasks Holdclose directly targets: managing medications and
refills (50%), scheduling appointments (46%), coordinating between doctors, and
tracking follow-ups and care plans.

Holdclose attacks these four tasks with refill-runway alerts, one-tap
appointment and dose-window management, voice-to-action logging, AI
scan-to-import (a prescription or appointment card becomes structured records in
seconds instead of manual entry), and a shared Care Circle that removes duplicated
"who did what" coordination across the family.

**Estimate.** If a caregiver carrying an 11+ hour coordination week recovers even
**15–25% of that time** through faster logging, automated refill tracking,
scan-to-import, and shared coordination, that is a conservative **~1.5 to ~3 hours
returned per week**. We present this as a **data-backed estimate, not a measured
result** — the derivation (CAN coordination hours × Holdclose's coverage of the
dominant coordination tasks) is explicit so a reviewer can weigh it. Measuring the
*actual* net time saved — instrumented in-app timing plus caregiver self-report,
against a pre-Holdclose baseline — is a defined Phase 2 metric (see Performance
Metrics and the pilot plan above).

## Bench Metrics — measurable today vs. the Phase 2 measurement plan

ACL's guide suggests basic bench-test metrics (F1, precision, recall, accuracy).
We report **only what we can measure honestly today** and lay out a plan for the
rest — no fabricated numbers.

**Measurable today — the safety guardrail pass-rate.** Our optional Data Output
Logs (`DATA_OUTPUT_LOGS.md`) drive **41 real inference cycles** through the actual
coach stack — 32 standard (including 2 thin-data uncertainty flags), 4 stress, and
5 boundary/safety cycles including a prompt-injection probe and the
Protocol-9-Delta unknown-term probe. **All 41 guardrails held (41/41):** every
dosing, diagnosis, prognosis, crisis, injection, and unknown-protocol case was
correctly refused or escalated, and the code-side crisis watchdog fired
independent of the model. That 41/41 pass-rate is the measurable safety result we
can stand behind now.

**Phase 2 measurement plan — classifier accuracy on a labeled corpus.** The
scan-to-import extractors (prescription, appointment, and insurance-card) are
classification-shaped and *are* the right surface for F1/precision/recall/accuracy.
We do **not** yet have a labeled test corpus, so we do not report those numbers.
In Phase 2 we will assemble a labeled corpus of real-world scans (with a
held-out test set), then measure **precision, recall, F1, and overall
field-extraction accuracy** per field type — with special weight on **recall of
low-confidence fields**, since the product's safety design is to flag uncertain
extractions for the caregiver to check rather than silently accept them.

## Data Privacy Procedures

Privacy-by-design and **local-first**: care data lives on the caregiver's
device by default. Care-circle sharing syncs through an **authenticated backend**
with single-use invite links and explicit join confirmation. All network traffic
is encrypted **in transit (TLS)**; on-device data is protected by **OS device
encryption**, and OS cloud backups are disabled so the local record is not swept
into iCloud or Google Drive (Android `allowBackup=false`; iOS files excluded from
backup). Server-synced care-circle data resides on Cloudflare D1 and R2. We do
**not** sell caregiver or care-recipient data; consent is explicit and revocable.
Holdclose is a consumer tool used by families directly, **not a HIPAA covered
entity**, but it is built privacy-forward to the standard families deserve.

## Evaluation, Safety & Bias Monitoring

- **AI guardrails:** system constraints keep the coach educational, **not
  diagnostic**; **human-in-the-loop confirmation** for any action that changes
  care data; an "I'm not certain — please consult a professional" escalation
  path; a community **crisis-keyword watchdog**.
- **Continuous monitoring:** log uncertain/escalated interactions for review;
  **red-team** coach outputs against unsafe-advice scenarios (an initial 41-cycle
  run through the real stack is documented in `DATA_OUTPUT_LOGS.md` — all safety
  guardrails held; the harness re-runs each iteration); track unsafe-response
  rate over time.
- **Bias:** recruit a **demographically diverse** caregiver test pool; watch for
  uneven quality across care situations, literacy levels, and (future)
  languages. The **model-agnostic** architecture lets us swap the underlying
  model if one underperforms for any subgroup — a concrete responsible-AI
  advantage.

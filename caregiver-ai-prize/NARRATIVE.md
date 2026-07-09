# Holdclose — ACL Caregiver AI Challenge (Track 1)

_Smart Innovation for Better Care: AI Solutions to Empower Caregivers._

_Consolidated submission narrative: Cover Page + Abstract + Project Narrative §1–§5, in official order. `[FOUNDER: …]` placeholders remain for the founder to fill before the final 508-compliant PDF/Word conversion._


---

# Cover Page

**Solution name:** Holdclose

**Team / organization:** JCSV One LLC, doing business as **Juno Code Studio**

**Track:** **Track 1 — AI Tools to Support Family Caregivers**

**Primary contact:**
- Name: [FOUNDER: full legal name]
- Email: [FOUNDER: contact email]
- Phone: [FOUNDER: contact phone]
- U.S. citizen / permanent-resident status: [FOUNDER: attest — "U.S. citizen"]

**Alternate contact (optional):** [FOUNDER: name/email/phone, or "N/A — solo entrant"]

**Team members & affiliations:** Solo entrant — [FOUNDER: name], Founder &
Developer, JCSV One LLC (Juno Code Studio). Planned Phase 2 caregiver and
clinical advisors to be secured through partnerships (see letters of support,
Appendix).

**Meritorious prize focus area (optional):** Caregivers supporting individuals
with Alzheimer's disease and related dementias (see Section 5).

---

## Abstract (≤250 words)

Family caregiving is not one hard moment — it is a relentless, often full-time
job made of thousands of them. An estimated 63 million Americans care for an
aging or ill loved one, most without training, while juggling work and their own
families. They track medications and narrow dose windows, watch shifting
symptoms, coordinate appointments and relatives, and carry the emotional weight —
usually with no one guiding them and no time to look anything up.

**Holdclose is the assistant to the caregiver:** a built and tested mobile app
(iOS + Android) that makes the whole experience easier. At its core is an AI
coach grounded in the loved one's real care data — medications, dose windows,
appointments, journal history, and the family care circle — so its guidance fits
*your* person instead of a blank chatbox. Around the coach sits a full caregiving
suite: effortless tracking, hands-free voice logging, a shared care circle, a
health log, an emergency card, and AI scan-to-import and doctor-visit prep, each
kept safe by human-in-the-loop confirmation before any care-data change.

Holdclose was built by a U.S. Air Force veteran who spent a decade inside VA
benefits systems and has repeatedly cared for his father, a 100%-disabled
veteran. The AI is model-agnostic and responsible: it augments the caregiver's
judgment rather than replacing it, educates rather than diagnoses, flags
uncertainty, and escalates to human help. It is a working product today — not a
concept — ready to validate with caregivers in Phase 2.


---

# Project Narrative


## 1. Understanding of Need and Solution Design

### Understanding of Need

Family caregiving is not a single hard moment — it is a relentless, often
full-time job made of thousands of them. An estimated **63 million** Americans
care for an aging or ill family member — on average **51 years old** and giving
about **27 hours a week** to roughly **$600 billion** in unpaid care each year
(Caregiver Action Network, 2026 Caregiver Tech Insights Survey, n = 272). Most do
it without training, many while holding other jobs and raising their own children.
They manage medications and narrow dose windows, track shifting symptoms,
coordinate appointments and other family members, and carry the emotional weight
of watching someone they love decline — usually with no one guiding them and no
time to stop and look anything up.

The coordination alone is a second job. In the CAN survey, **37% of caregivers
spend 11 or more hours a week on care coordination**, and nearly **one in three**
describe their loved one's care as *fragmented* across too many systems and
providers. The most time-consuming coordination burdens are exactly the ones
Holdclose was built to absorb: **managing medications and refills (50%)** and
**scheduling appointments (46%)**.

Existing help does not fit the reality. Generic resources — websites,
hotlines, pamphlets — do not know the specific loved one, and professional
support is expensive and rationed. The unmet need is not more information; it is
**an assistant**: something that lightens the daily operational and emotional
load of caregiving, lives in the caregiver's pocket, and works at the moment of
need — often when the caregiver's hands are literally full. Left unmet, the
consequences are the ones ACL's mission exists to prevent: caregiver burnout,
medication errors, family conflict, and premature, costly institutionalization.

This need is not abstract to us. Holdclose was built by a **U.S. Air Force
veteran** who spent a decade working inside VA benefits systems (the Veterans
Benefits Management System) and who has repeatedly helped care for his own
father — a **100% disabled veteran**. It was shaped further with friends who are
themselves family caregivers of aging and dementia-affected parents. We have not
guessed at this problem; we have lived it — including at the exact intersection
this Challenge and its VA partner serve: the estimated **5.5 million Americans
caring for a veteran**, a population served by the VA Caregiver Support Program
yet still stretched thin. Holdclose serves *any* care situation, but its roots
are in caring for those who served.

### Solution Design

**Holdclose is the assistant to the caregiver** — not a cure, not a replacement
for human care, but a mobile app (iOS + Android) that makes a hard, full-time
job easier across the whole experience. Its components:

- **An AI coach for the hard moments** — a multi-turn companion *grounded in the
  loved one's real care data* (medications, dose windows, appointments, journal
  history, the family care circle). Because it knows *your person*, its guidance
  is personalized, not generic — that grounding is the point.
- **Effortless tracking** of symptoms and medications — health log, care-plan
  routines, medications with dose windows and a dose log, appointments, and an
  **Emergency Card** that hands off to paramedics/ER in a crisis.
- **Voice-to-action logging** — hands-free voice intent ("log that she didn't
  sleep") records meds, doses, appointments, and journal entries for the
  caregiver, for the constant reality that their hands are full. Every AI action
  that changes existing care data — in chat *or* voice — routes through an
  explicit confirmation card before it is applied.
- **A Journal with pattern detection** that surfaces early warnings
  ("3+ falls this week").
- **A Care Circle** that shares caregiving across a family or care team
  (calendar, tasks, shifts, expenses) — supporting, never replacing, human
  connection.
- **A caregiver community** with a crisis-keyword safety watchdog.

The AI is integrated responsibly and is **model-agnostic**: the AI runs on
**Cloudflare Workers AI** — an open-weight model on our own cloud infrastructure —
so the loved one's data never goes to a separate AI vendor, and the architecture
can swap the underlying model without touching the
product. It supports the caregiver's judgment rather than replacing it, educates
rather than diagnoses, flags uncertainty when data is thin, and escalates to
human help. Data is local-first and private, and the product is designed to be
**affordable** — because it exists to help families, not to extract from them.

### AI Current Stage of Development (TRL 3+)

Holdclose is a **complete, functioning, tested application — not a concept.**
It is a Flutter app running on physical iOS and Android devices, with unit,
widget, golden, and end-to-end integration suites green and a deployed Cloudflare
Worker backend providing care-circle sync. This exceeds TRL-3
(experimental proof-of-concept): the technology is built and demonstrated in a
realistic environment. The AI coach calls a large language model via a
quota-enforcing backend, behind guardrails — system constraints that keep
responses supportive and non-diagnostic, an uncertainty clause that has the coach
say when it is unsure and point to human help, weak-data flagging in the
scan-to-import extractors, a code-side (non-LLM) crisis watchdog on chat and
voice, and human-in-the-loop confirmation before any AI action changes existing
care data. The architecture is **model-agnostic** — the AI runs on **Cloudflare
Workers AI** (an open-weight model on our own cloud infrastructure), so the loved
one's data never goes to a separate AI vendor and Holdclose is not dependent on
any single AI provider.

**Readiness self-assessment.** TRL-3 is the eligibility floor; **Holdclose
clears it and stands above it — a working, tested system demonstrated in a
realistic environment, not a proof-of-concept.** We map our evidence to ACL's
five readiness elements:

- **Concept feasibility** — The approach combines *existing* foundation models
  with a *custom* data-grounding pipeline; feasibility is established by the
  running system, not by simulation alone.
- **Experimental validation** — A full prototype is built and exercised: unit,
  widget, golden, and end-to-end integration suites run green, and the app runs
  on physical iOS and Android devices.
- **Testing in a relevant environment** — The coach operates against real,
  sanitized care data (medications, dose windows, appointments, journal) on the
  actual phones caregivers use — the true environment of use, not a lab bench.
- **Critical technical elements identified and tested** — The load-bearing
  elements — the `chat_context_builder` grounding layer, the human-in-the-loop
  confirmation flow, and the safety/uncertainty guardrails — are each built and
  verified, not aspirational.
- **Traceable documentation** — Architecture, tests, and safety guardrails are
  version-controlled and documented, so every claim above traces to code.

In short, Holdclose sits well beyond TRL-3 (a functioning system demonstrated in
a realistic setting), while remaining honest that operational proof *at scale* —
outcome data from a caregiver cohort — is precisely the work of Phases 2 and 3.

**Existing vs. new AI methods.** Holdclose does *not* train a new model — it
builds on **existing large language models** (model-agnostic; the AI runs on
**Cloudflare Workers AI**, an open-weight model on our own cloud infrastructure,
so the loved one's data never goes to a separate AI vendor). Its distinct
contribution is the **data-grounding layer**
(`chat_context_builder`): the loved one's real, *sanitized* care data — meds, dose
windows, appointments, journal — is assembled into the model's context at
inference, so a general-purpose LLM becomes a coach that knows *your specific
person*. That combination — proven foundation models + a novel, privacy-guarded
context-assembly pipeline with human-in-the-loop guardrails — is the technology.

### End-User Input

Holdclose's design has been shaped by family caregivers from the start.
[N] early testers — friends who are themselves caregivers of aging parents,
including one who cared for a parent with dementia — used the app and gave
feedback that **directly changed the product**. Most notably, an early
structured "behavior decoder" flow was removed after testers consistently
preferred the open, data-grounded chat coach. [Add 1–2 more concrete changes.]

To broaden input beyond our immediate circle, we are running **structured
feedback sessions in July 2026** with additional family caregivers recruited
from online caregiver communities, and we will continue caregiver co-design
through Phases 2 and 3.

### Supporting Research

The need Holdclose addresses — and the specific features we built — are
corroborated by the Challenge's **own non-federal judging partner**, the
**Caregiver Action Network (CAN)**, whose **2026 Caregiver Tech Insights Survey**
(n = 272 family caregivers) was presented at ACL's May 28, 2026 Challenge webinar.
Because CAN is the organization judging this very Track, its data reflects the
exact population and priorities the Challenge is asking us to serve — and its
findings map almost one-to-one onto the features Holdclose already ships.

**Caregivers are already reaching for AI — and want it grounded and
trustworthy.** In the CAN survey, **59% have used or tried AI** for caregiving.
The leading uses line up directly with Holdclose's capabilities:

| CAN caregiver AI use case | Share | The Holdclose feature that does it |
|---|---|---|
| Understanding a diagnosis or condition | **44%** | the data-grounded coach |
| Preparing questions for doctor visits | **32%** | AI doctor-visit prep |
| Organizing medical information | **27%** | the care suite (meds, appts, health log) |
| Receiving emotional support | **24%** | the coach |
| Writing insurance appeals | **22%** | AI insurance-appeal drafting |
| Admin / care-coordination assistance | **21%** | the Care Circle + scan-to-import |

Every one of these is a feature Holdclose ships today. The difference is that
Holdclose's coach is **grounded in the loved one's real record** — meds, dose
windows, appointments, journal — rather than a blank chatbox, so its help fits
*your* person.

**What caregivers most want to delegate is exactly what Holdclose automates.**
Asked which tasks they would most like to hand off, caregivers named **tracking
follow-ups and care plans (43%)**, **finding providers (43%)**, **managing
prescription refills (43%)**, **coordinating between doctors (41%)**, and
**scheduling appointments (40%)** (CAN 2026). Holdclose targets this list head-on:
refill-runway alerts, NPI-based "Find a provider" search, appointment management,
and a shared Care Circle for coordination. The wish list *is* the feature list.

**The adoption barriers validate our core design choices.** The top barriers to
caregiver technology adoption are **cost (43%)**, **not knowing which products to
trust (42%)**, and **privacy and security concerns (40%)** (CAN 2026). Holdclose
answers each directly, and Section 4 (Principle 7) shows how: an **affordable**
model; a **trustworthy, non-diagnostic** coach whose reasoning is visible and
grounded; and a **local-first, vendor-invisible** privacy architecture in which
the loved one's data never goes to a separate AI vendor.

**Primary source.** Caregiver Action Network, *2026 Caregiver Tech Insights
Survey* (n = 272 family caregivers), presented at ACL, *Smart Innovation for
Better Care — The Caregiver Experience* (Caregiver AI Prize Challenge
informational webinar), May 28, 2026.

[Optional, if page budget allows: AARP/NAC *Caregiving in the U.S. 2025*; AARP
*Valuing the Invaluable 2023* ($600B unpaid-care valuation); peer-reviewed
literature on caregiver burden → premature institutionalization.]


---


## 2. Implementation Approach

### Deployment Readiness

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

### Implementation, Testing & Evaluation Strategy

- **Now–July 2026:** structured caregiver feedback sessions (existing
  family-caregiver testers + additional caregivers recruited from caregiver
  communities); refine based on what they tell us.
- **Phase 2 (if advanced):** TestFlight → App Store pilot with a cohort of
  [N] family caregivers over [8–12] weeks, instrumented for the metrics below;
  weekly iteration on feedback; safety review of AI-coach interactions.
- **Phase 3:** broaden distribution and establish sustainability (affordable
  pricing and/or caregiver-org partnerships) so the tool outlasts the grant.

### Timeline & Milestones

| When | Milestone |
|---|---|
| Now–Jul 2026 | Caregiver co-design sessions; refine; secure partner input |
| Sep 2026 | (If Phase 1 win) finalize App Store release; recruit pilot cohort |
| Phase 2 (2026–27) | Run instrumented pilot; collect performance + safety data; iterate |
| Phase 3 | Scale reach; establish affordable, sustainable model |

### Team & Roles

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

### Performance Metrics

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

### Net Time Saved (data-backed estimate)

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

### Bench Metrics — measurable today vs. the Phase 2 measurement plan

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

### Data Privacy Procedures

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

### Evaluation, Safety & Bias Monitoring

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


---


## 3. Usability and Integration

### Error Prevention & Supporting Human Judgment

Holdclose is designed so the AI **supports the caregiver's judgment, never
overrides it.** Any AI action that changes existing care data — adding, editing,
or deleting a medication, dose, appointment, or journal entry, and every
destructive delete/cancel — routes through an explicit **in-thread confirmation
card** before it is applied. This gating applies to **voice mode as well as
chat**, so a mistranscribed or hallucinated change (for example a dosage edit)
cannot be written silently; the caregiver sees and confirms it first. The coach
is scoped to be **educational, not diagnostic**, and defers to professionals on
medical decisions.

**Actionable workflow — Input → AI Analysis → Caregiver Action.** The
scan-to-import flow shows the pattern concretely. The caregiver is always the
last step before any care-data change:

```
  ┌──────────────┐    ┌────────────────────┐    ┌─────────────────────┐    ┌──────────────────┐
  │  1. INPUT    │    │  2. AI ANALYSIS    │    │ 3. CAREGIVER ACTION │    │  4. RESULT       │
  │              │──▶ │                    │──▶ │  (human-in-the-loop)│──▶ │                  │
  │ Photograph a │    │ Model extracts     │    │ Review screen shows │    │ Medication +     │
  │ prescription │    │ drug, dose,        │    │ each field; low-    │    │ dose windows are │
  │ label with   │    │ frequency, refills │    │ confidence fields   │    │ created in the   │
  │ the camera   │    │ into structured    │    │ are flagged amber   │    │ care record only │
  │              │    │ fields; flags any  │    │ ("check this").     │    │ after the        │
  │              │    │ uncertain field    │    │ Caregiver edits +   │    │ caregiver taps   │
  │              │    │ instead of         │    │ approves — or       │    │ Approve.         │
  │              │    │ guessing.          │    │ discards.           │    │                  │
  └──────────────┘    └────────────────────┘    └─────────────────────┘    └──────────────────┘
```

Nothing is written to the care record until the caregiver approves it. The same
Input → AI → **caregiver-confirms** → Result shape governs the chat/voice coach
(any data-changing action parks behind an in-thread confirmation card) and the
appointment-card and insurance-card scanners — one consistent, human-in-the-loop
pattern across every AI surface.

### Transparency & Explainability

The coach is clearly an **AI assistant, not a clinician.** Its guidance is
**grounded in the loved one's actual care data** (meds, dose windows,
appointments, journal), so the caregiver can see *why* it responds as it does.
When the model is uncertain, it says so and points to human help rather than
guessing. The caregiver can see and edit everything the coach draws on — no
hidden data use.

### Usability

Holdclose is built for the real caregiver: exhausted, time-poor, often with
their hands full. The interface prioritizes **speed and low friction** —
voice-first logging, minimal taps, a chat-root home screen. Accessibility is a
first-class concern for an older-adult-adjacent audience: an in-app text-size
control layered on the OS's own Dynamic Type / font-scale setting, simple linear
flows, and a warm, high-contrast palette — with contrast and touch-target
conformance being brought fully to WCAG AA as part of ongoing hardening. UI
consistency is enforced by **golden tests on every screen**. Usability has
already been checked with family-caregiver testers and will be validated further
in structured July 2026 sessions with additional caregivers.

### Integration & Interoperability

- **Emergency Card** — a paramedic/ER handoff sheet that surfaces the essentials
  in a crisis, bridging the home-to-hospital gap.
- **Care Circle** — server-backed sync shares the care picture across a family
  or care team on multiple devices (calendar, tasks, shifts, expenses).
- **Cards & Docs scanning** — capture insurance cards and key documents.
- **Provider-shareable care summary** — a care-summary PDF export and NPI-based
  "Find a provider" search already ship today, bridging the caregiver to the
  clinical side.
- **Roadmap (planned, not current):** direct interoperability with health
  records / EMRs and assistive/home devices — described honestly as future work,
  not a present capability.


---


## 4. Alignment with Caregiver AI Principles

Holdclose was designed around ACL's seven Caregiver AI Principles. Each is met by
a real, shipped feature:

**1. Protect privacy, dignity, and choice.** Care data is **local-first** —
stored on the caregiver's device by default. Sharing is opt-in via single-use,
explicitly confirmed invites. **Data portability** is inherent (the caregiver
owns and can export their record); we do **not** sell caregiver or care-recipient
data; consent is explicit and revocable. The app refers to the care recipient as
"your loved one," never "the patient" — dignity by design. All network traffic is
encrypted **in transit (TLS)**; on-device care data is protected by the phone's
**OS device encryption**, with OS cloud backups disabled so the local record is
not swept into iCloud or Google Drive (Android `allowBackup=false`; iOS files
excluded from backup). Server-synced care-circle data resides on Cloudflare D1
and R2. Critically, **the AI itself runs on Cloudflare Workers AI** — an
open-weight model on our own cloud infrastructure — so the loved one's care data
used to ground the coach **never goes to a separate AI vendor**. There is no
third-party model provider in the data path to trust; the privacy boundary is
ours to hold.

**2. Support human-in-the-loop accountability.** Holdclose **augments, never
replaces, the caregiver's judgment.** Every AI action that changes existing care
data — in chat *or* voice — routes through an explicit **confirmation card**
before it applies; the coach's guidance is **grounded in and cites the loved
one's own data**, so the caregiver sees the reasoning; and when the model is
uncertain or the data is thin, it **flags that weak-data result and escalates to
professional help** rather than asserting. The scan-to-import extractors likewise
flag low-confidence fields for the caregiver to check, and a code-side (non-LLM)
crisis watchdog on chat and voice catches concerning messages even if the model
fails.

**3. Support caregivers' well-being and reduce burden.** This is Holdclose's
purpose — **the assistant that makes a relentless, full-time job easier.**
Hands-free voice logging removes friction when hands are full; the coach reduces
the "I don't know what to do" stress of the hard moments; tracking and the
Emergency Card cut cognitive load and crisis risk — assisting with the work *and*
the emotional weight.

**4. Supplement, not replace, human connection.** The **Care Circle** spreads
caregiving across the family instead of isolating one person, and the caregiver
**community** connects people who are otherwise alone. The AI is a tool; the
humans do the caring — Holdclose strengthens the caregiver↔loved-one and
caregiver↔family relationships rather than substituting for them.

**5. Allow personalized and flexible care.** Guidance is **grounded in the
specific loved one's situation** (their meds, history, journal), and Holdclose
works for **any** care situation — aging parents, disability, recovery, dementia
— customizable to individual needs, preferences, and lifestyle, not a single
diagnosis or a one-size template.

**6. Promote safety, reliability, and transparency.** The coach's behavior is
**transparent** (educational, not diagnostic; grounded and cited; uncertainty
flagged) and **designed to avoid bias**: a code-side (non-LLM) **crisis-keyword
watchdog** on chat, voice, and the community routes concerning content to human
help even if the model fails, human-in-the-loop confirmation gates every care-data
change, and the **model-agnostic** architecture lets us replace a model that
underperforms for any caregiver group. We **red-teamed** the coach against
unsafe-advice scenarios and published the results as our Data Output Logs
(`DATA_OUTPUT_LOGS.md`): 41 cycles through the real chat stack — 32 standard, 4
stress, 5 boundary/safety plus a refusal probe — in which every guardrail held
(41/41), including refusals of a dose-change request, a diagnosis request, a
prompt-injection embedded in shared family notes, and an unknown-protocol probe,
and a code-side crisis referral that fires independent of the model. This
reflects current evidence and best practices, with safeguards against adverse
impacts, and the harness re-runs as the product evolves.

**7. Ensure affordability and access.** The Challenge's own judging partner
measured exactly what keeps caregivers off of helpful technology. In the Caregiver
Action Network 2026 Caregiver Tech Insights Survey (n = 272), the top three
adoption barriers are **cost (43%)**, **not knowing which products to trust
(42%)**, and **privacy and security concerns (40%)**. Holdclose's core design
choices answer each one directly:

- **Cost (43%).** Holdclose is designed to be **affordable** [FOUNDER: state the
  pricing commitment — e.g. "a free core tier plus an optional low-cost
  subscription; transparent, reasonable pricing"] and runs on the phone caregivers
  already carry, so there is no new hardware to buy.
- **Don't-know-which-to-trust (42%).** The coach is **non-diagnostic and
  transparent** — its guidance is grounded in and cites the loved one's own data,
  it flags uncertainty, and human-in-the-loop confirmation gates every care-data
  change (Principles 2 and 6), so a caregiver can see *why* it says what it says.
- **Privacy and security (40%).** Holdclose is **local-first**, and the AI runs on
  **Cloudflare Workers AI** (an open-weight model on our own cloud infrastructure),
  so the loved one's data **never goes to a separate AI vendor** (Principle 1).

Its **local-first** design also works even with limited connectivity, meeting
caregivers where they are — the heart of ACL's home- and community-based mission.


---


## 5. Meritorious Prize Eligibility (Optional)

Holdclose is submitted for meritorious prize consideration under the priority
focus area: **"Caregivers supporting individuals with Alzheimer's disease and
related dementias."**

Holdclose is exceptionally well-suited to dementia caregiving — it **began as a
dementia-focused tool** and retains deep capability for this population even as
it generalized to any care situation:

- **A data-grounded coach for dementia's hardest moments.** Dementia caregivers
  face confusing, distressing behaviors — agitation, wandering, repetition,
  sundowning — they are unequipped to interpret. Holdclose's coach, grounded in
  the specific loved one's history, medications, and journal, helps caregivers
  understand and respond, and escalates to professional help when appropriate.
- **Symptom and behavior tracking** with a pattern detector that surfaces
  decline signals over time — critical in a progressive condition.
- **Care Circle** coordination across the family, essential as dementia care
  intensifies into a multi-person, round-the-clock responsibility.
- **Emergency Card** for the crises and hospitalizations common in advanced
  dementia.

This focus is personal: the founder's own grandfather lived with dementia, and
Holdclose's earliest design was shaped by that experience and by dementia-
caregiver feedback.

**Secondary consideration (interoperability focus areas #3–#4):** Holdclose
already ships one concrete provider-interoperability artifact — the
one-tap, provider-shareable **care-summary PDF** (crisis info + medications +
appointments) a caregiver can hand to a new doctor or ER. Deeper
interoperability with health records/EMRs and assistive/home devices is
described honestly as *planned* work in Sections 2–3 — a directional fit, not
a current claim.


---

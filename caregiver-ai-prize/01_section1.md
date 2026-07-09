# Section 1 — Understanding of Need and Solution Design

> Draft. Uses the official sub-headings. `[BRACKETS]` = fill with real detail
> before submission. Written in the "assistant to the caregiver" framing.

## Understanding of Need

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

## Solution Design

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

## AI Current Stage of Development (TRL 3+)

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

## End-User Input

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

## Supporting Research

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

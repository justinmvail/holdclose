# Section 1 — Understanding of Need and Solution Design

> Draft. Uses the official sub-headings. `[BRACKETS]` = fill with real detail
> before submission. Written in the "assistant to the caregiver" framing.

## Understanding of Need

Family caregiving is not a single hard moment — it is a relentless, often
full-time job made of thousands of them. More than 53 million Americans care
for an aging or ill family member, most without training, many while holding
other jobs and raising their own children. They manage medications and narrow
dose windows, track shifting symptoms, coordinate appointments and other family
members, and carry the emotional weight of watching someone they love decline —
usually with no one guiding them and no time to stop and look anything up.

Existing help does not fit the reality. Generic resources — websites,
hotlines, pamphlets — do not know the specific loved one, and professional
support is expensive and rationed. The unmet need is not more information; it is
**an assistant**: something that lightens the daily operational and emotional
load of caregiving, lives in the caregiver's pocket, and works at the moment of
need — often when the caregiver's hands are literally full. Left unmet, the
consequences are the ones ACL's mission exists to prevent: caregiver burnout,
medication errors, family conflict, and premature, costly institutionalization.

This need is not abstract to us. Holdclose was built by a developer who lived
dementia in his own family [grandfather], and shaped with friends who are
themselves family caregivers of aging and dementia-affected parents. We are not
guessing at the problem; we have carried it.

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
  caregiver, for the constant reality that their hands are full. Any action that
  changes care data routes through an explicit confirmation card.
- **A Journal with pattern detection** that surfaces early warnings
  ("3+ falls this week").
- **A Care Circle** that shares caregiving across a family or care team
  (calendar, tasks, shifts, expenses) — supporting, never replacing, human
  connection.
- **A caregiver community** with a crisis-keyword safety watchdog.

The AI is integrated responsibly and is **model-agnostic** (currently built on
Claude): it supports the caregiver's judgment rather than replacing it, educates
rather than diagnoses, flags uncertainty, and escalates to human help. Data is
local-first and private, and the product is designed to be **affordable** —
because it exists to help families, not to extract from them.

## AI Current Stage of Development (TRL 3+)

Holdclose is a **complete, functioning, tested application — not a concept.**
[Flutter; iOS + Android; deployed to device; unit/widget/golden and end-to-end
test suites green; server-backed care-circle sync.] This exceeds TRL-3
(experimental proof-of-concept): the technology is built and demonstrated in a
realistic environment. The AI coach calls a large language model via API behind
guardrails — system constraints that keep responses supportive and
non-diagnostic, an uncertainty/escalation path to human help, and human-in-the-
loop confirmation before any action changes care data. The architecture is
**model-agnostic**, so Holdclose is not dependent on any single AI provider.

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

[To add — 4–6 citations: AARP/NAC "Caregiving in the U.S." on caregiver
prevalence and burden; literature on caregiver burnout → institutionalization;
the value of just-in-time, personalized caregiver support; medication-adherence
/ error-reduction evidence. Draft list to follow.]

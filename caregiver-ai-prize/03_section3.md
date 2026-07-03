# Section 3 — Usability and Integration

> Draft. Official sub-headings. `[BRACKETS]` = fill/verify.

## Error Prevention & Supporting Human Judgment

Holdclose is designed so the AI **supports the caregiver's judgment, never
overrides it.** Any action that changes care data — logging or deleting a
medication, dose, appointment, or journal entry — routes through an explicit
**in-thread confirmation card** before it is applied; destructive actions
(delete/cancel) always require confirmation. Voice-logged actions are surfaced
for the caregiver to confirm. The coach is scoped to be **educational, not
diagnostic**, and defers to professionals on medical decisions.

## Transparency & Explainability

The coach is clearly an **AI assistant, not a clinician.** Its guidance is
**grounded in the loved one's actual care data** (meds, dose windows,
appointments, journal), so the caregiver can see *why* it responds as it does.
When the model is uncertain, it says so and points to human help rather than
guessing. The caregiver can see and edit everything the coach draws on — no
hidden data use.

## Usability

Holdclose is built for the real caregiver: exhausted, time-poor, often with
their hands full. The interface prioritizes **speed and low friction** —
voice-first logging, minimal taps, a chat-root home screen. [Accessibility:
large-text support, simple flows, high-contrast warm palette.] UI consistency is
enforced by **golden tests on every screen**. Usability has already been checked
with family-caregiver testers and will be validated further in structured
July 2026 sessions with additional caregivers.

## Integration & Interoperability

- **Emergency Card** — a paramedic/ER handoff sheet that surfaces the essentials
  in a crisis, bridging the home-to-hospital gap.
- **Care Circle** — server-backed sync shares the care picture across a family
  or care team on multiple devices (calendar, tasks, shifts, expenses).
- **AI scan-to-import** — photograph a prescription label, appointment card,
  or insurance card and the app extracts the fields into a structured draft
  the caregiver reviews and approves before anything is saved (a second,
  explicit human-in-the-loop gate). Prescriptions become medications;
  appointment cards become appointments with reminders; insurance cards fill
  the Emergency Card.
- **AI visit prep & appeals** — one tap drafts relevant, non-diagnostic
  questions to bring to a doctor's visit; another drafts an insurance-appeal
  letter (explicitly not legal or medical advice) the caregiver edits and
  sends.
- **Find a provider** — searches the free public CMS NPI Registry by name,
  specialty, and city/state to add a clinician to the care record.
- **Provider-shareable care summary** — one tap generates a shareable PDF of
  the essentials (crisis info, medications, appointments) for a new doctor or
  ER visit — bridging the coordination gap the CAN survey flags (41% of
  caregivers struggle to coordinate between providers).
- **Refill-runway alerts & tap-to-call** — arithmetic on the caregiver's own
  captured label data flags when a medication is running low, with a
  one-tap call to the pharmacy; providers and insurers are tap-to-call too.
- **Roadmap:** deeper interoperability with health records/EMRs and
  assistive/home devices remains genuinely future work.

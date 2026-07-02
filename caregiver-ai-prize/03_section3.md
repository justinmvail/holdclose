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
- **Cards & Docs scanning** — capture insurance cards and key documents.
- **Roadmap:** provider-shareable care summaries, and — longer term —
  interoperability with health records/EMRs and assistive devices. [State
  current capability vs. planned honestly; don't overclaim.]

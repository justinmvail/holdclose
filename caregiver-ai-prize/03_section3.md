# Section 3 — Usability and Integration

> Draft. Official sub-headings. `[BRACKETS]` = fill/verify.

## Error Prevention & Supporting Human Judgment

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
voice-first logging, minimal taps, a chat-root home screen. Accessibility is a
first-class concern for an older-adult-adjacent audience: an in-app text-size
control layered on the OS's own Dynamic Type / font-scale setting, simple linear
flows, and a warm, high-contrast palette — with contrast and touch-target
conformance being brought fully to WCAG AA as part of ongoing hardening. UI
consistency is enforced by **golden tests on every screen**. Usability has
already been checked with family-caregiver testers and will be validated further
in structured July 2026 sessions with additional caregivers.

## Integration & Interoperability

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

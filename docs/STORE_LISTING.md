# App Store Submission Content — Holdclose

Draft content for the App Store (iOS) and Google Play listings, plus the
privacy declarations and a pre-submission compliance checklist. Derived from
the shipping app, `backend/src/routes/legal.ts` (Terms + Privacy), and
`CLAUDE.md`.

> **Provenance / accuracy note.** Everything here describes what is actually
> shipped. Privacy declarations are pulled from the live Privacy Policy at
> `holdclose.care/privacy` (source: `backend/src/routes/legal.ts`). If the
> policy changes, re-derive Sections 1–2 below. The policy text has **not yet
> had attorney review** (flagged in `legal.ts`) — schedule that before you
> submit. Do not invent features to fill a store field; leave it out.

Publisher: **Juno Code Studio (JCSV One LLC)**, a South Carolina LLC.
Brand / support: **holdclose.care** · support@holdclose.care

---

## 1. App Store (iOS) — App Privacy "Nutrition Labels"

Fill these into **App Store Connect → App Privacy**. Holdclose collects the
data types below. **Nothing is used for tracking** (no cross-app/cross-site
tracking, no ad networks, no data brokers) and **no data is sold**. Storage is
**on-device by default** — care data lives in a local database on the phone and
only reaches our servers for features the caregiver turns on (Care Circle sync,
AI features, feedback reports).

For each type, App Store Connect asks: (a) Is it **collected**? (b) Is it
**linked to the user's identity**? (c) Is it **used for tracking**? (d) What is
the **purpose**?

### Health & Fitness — care data
- **Health**: Yes, collected.
- **Linked to identity**: Yes (tied to the signed-in account when synced;
  local-only when not signed in).
- **Used for tracking**: No.
- **Purpose**: App Functionality. Medications, dose logs, appointments, health
  log entries, journal entries, and the emergency card are recorded to run the
  caregiving features and — only when the caregiver invokes an AI feature — to
  generate coach replies and document extractions on our own infrastructure.

### Contact Info
- **Name**: Yes, collected — the display name Google/Apple asserts at sign-in.
- **Email Address**: Yes, collected — the email from the sign-in provider.
- **Linked to identity**: Yes.
- **Used for tracking**: No.
- **Purpose**: App Functionality (account creation, recognizing the account
  across devices, Care Circle membership). We never receive the sign-in
  password.

### User Content
- **Photos or Videos**: Yes, collected — photos attached to journal entries and
  images captured for document scanning (prescriptions, appointment cards,
  insurance cards).
- **Other User Content**: Yes, collected — free-text journal entries, coach chat
  messages, and the care context sent with them.
- **Linked to identity**: Yes (when synced or sent to an AI feature).
- **Used for tracking**: No.
- **Purpose**: App Functionality. Journal/photo content is stored to power the
  journal and (when the caregiver invokes it) the coach; scanned documents are
  processed to extract fields the caregiver then reviews and approves.

### Identifiers
- **User ID**: Yes, collected — the account identifier (the Google/Apple
  subject) and the internal user id used for Care Circle sync.
- **Linked to identity**: Yes.
- **Used for tracking**: No.
- **Purpose**: App Functionality.
- *(No Device ID / advertising identifier is collected.)*

### Diagnostics
- **Crash Data**: Yes, collected — but only when the caregiver **submits an
  in-app feedback report** and leaves the crash-log toggle on (it appears only
  when a prior-launch crash trace exists). Not collected automatically.
- **Other Diagnostic Data**: Yes — a recent app-log snapshot, attached to a
  feedback report (toggle on by default, declinable).
- **Linked to identity**: No (feedback reports carry what the user chooses; a
  screenshot toggle is **off by default** because a screen can show PHI).
- **Used for tracking**: No.
- **Purpose**: App Functionality (diagnosing issues the user reports). No
  third-party analytics or crash SDK is embedded.

### Data explicitly NOT collected
Location, Financial Info, Browsing/Search History, Sensitive Info (as an
Apple category — note care data is health data and declared above), Contacts
(the phone's address book), Advertising Data, and any Device/Advertising
identifier. No third-party analytics or ad SDKs.

### Subprocessor / where AI runs (for the reviewer's context)
Our sole infrastructure subprocessor is **Cloudflare, Inc.** — it hosts the
backend, database, and file storage **and** runs the AI (Cloudflare Workers AI)
that powers the coach and document scanning. Because the AI runs on the same
infrastructure that already stores synced care data, **data is not sent to a
separate AI vendor**. Prompts and responses are not retained after the request
and are not used to train any model.

### Account deletion
Supported in-app: **Settings → Delete account** deletes the account and all
server-synced data (server-side first, then local). Also available by emailing
support@holdclose.care.

---

## 2. Google Play — Data Safety Form

Fill these into **Play Console → App content → Data safety**. Same underlying
facts as Section 1, in Play's structure.

**Global answers**
- Does your app collect or share any of the required user data types? **Yes.**
- Is all of the user data **encrypted in transit**? **Yes** (sync and AI
  traffic is HTTPS/TLS).
- Do you provide a way for users to **request that their data be deleted**?
  **Yes** — in-app (**Settings → Delete account**) and by emailing
  support@holdclose.care.
- Is any data **shared** with third parties? **No** (Cloudflare is a
  subprocessor/service provider acting on our instructions — under Play's
  definitions, processing by a service provider is not "sharing"). **No data is
  sold. No data is shared with advertisers.**

**Data collected** (all: collected, encrypted in transit, deletable, **not**
shared, **not** for advertising/marketing, **not** for tracking):

| Category → Type | Collected | Purpose |
|---|---|---|
| Personal info → Name | Yes | Account management |
| Personal info → Email address | Yes | Account management |
| Personal info → User IDs | Yes | Account management, App functionality |
| Health & fitness → Health info | Yes | App functionality (care data: meds, dose logs, appointments, health log, emergency card) |
| Photos and videos → Photos | Yes | App functionality (journal photos, document scans) |
| Messages → Other in-app messages | Yes | App functionality (coach chat) |
| App activity → Other user-generated content | Yes | App functionality (journal entries, scanned-document content) |
| App info & performance → Crash logs | Yes | App functionality (only in a user-submitted feedback report) |
| App info & performance → Diagnostics | Yes | App functionality (log snapshot in a user-submitted feedback report) |

**Data collection is optional?** Yes, in practice — care data never leaves the
device unless the caregiver signs in, joins a Care Circle, or invokes an AI
feature; feedback attachments are per-report toggles.

**Data NOT collected**: Location, Financial info, Contacts (address book), Web
browsing history, Calendar, Device/other IDs for advertising. No third-party
ad or analytics SDK.

---

## 3. Listing Copy

### App name
**Holdclose**

### iOS subtitle (≤ 30 chars)
`Caregiving, together` (20) — alternates:
- `Care coach for family` (21)
- `Hold the ones you love` (22)

### Play short description (≤ 80 chars)
`A caregiving companion with a coach that knows your loved one's care.` (68)

### Full description (~3–4 paragraphs)

> Voice/compliance guardrails applied: no medical claims, no LLM
> vendor/model names, no emoji on CTAs, care recipient referred to as "your
> loved one" / "your person."

```
Caring for someone you love is a lot to hold. Holdclose keeps it in one
calm place: the medications and their dose windows, the appointments, a
shared care circle, a health log, a journal, and an emergency card — so
nothing important slips through on a hard day.

At the center is a coach that actually knows your person's situation. It
draws on the care details you've recorded — the medications, the schedule,
the recent history — so its help is grounded in your reality instead of
generic advice. Ask it to make sense of a busy week, draft the questions
worth asking at the next appointment, or prepare an insurance appeal letter,
and it starts from what's already true for your loved one.

Holdclose also cuts the busywork of coordination. Scan a prescription label,
an appointment card, or an insurance card and the app pulls out the details
for you to review and approve — you're always in control. Refill-runway
alerts flag a medication before it runs out, tap-to-call reaches a provider
or pharmacy, and a shareable care summary brings a new helper up to speed in
minutes. Invite family into a shared care circle and everyone sees the same
up-to-date plan.

Your care data lives on your device by default and only syncs when you
choose to share it. There are no ads, and we never sell your data. Holdclose
is a caregiving companion, not a medical device — it doesn't diagnose,
recommend doses, or replace your loved one's care team.
```

### Keyword suggestions (iOS keyword field — comma-separated, ~100 chars)
`caregiver,caregiving,medication,reminder,elderly,dementia,family,appointments,pill,care,aging,parent`

Additional ASO themes (for Play's indexed description / A/B): *care circle,
medication tracker, med reminder, senior care, caregiver support, dose
schedule, health log, appointment tracker, family caregiver.*

### Category — recommendation
**Medical.** Holdclose is a medication- and care-coordination tool with health
data at its core; **Medical** matches reviewer expectations and the medical
disclaimer posture better than the wellness-leaning **Health & Fitness**. Use
**Medical** as primary on both stores. (If a secondary is offered, **Health &
Fitness** is the reasonable second.)

### Support URL
`https://holdclose.care` (support: support@holdclose.care)
Privacy policy: `https://holdclose.care/privacy` · Terms:
`https://holdclose.care/terms`

### Screenshot shot-list (capture in this order)
Capture from a seeded demo build (post-stroke + hypertension persona) so no
real PHI ships. One caption line each; keep captions benefit-led, no emoji.

1. **Home** (`home_screen`) — "Today's care, at a glance."
2. **Chat coach** (`chat/chat_screen`) — "A coach that knows your person."
3. **Care hub** (`medical/medical_hub`) — "Everything in one calm place."
4. **Medication list + dose windows** (`medication/medication_list`) — "Meds
   and dose windows, on schedule."
5. **Prescription scan review** (`medication/medication_import_review`) — "Scan
   a label — you approve every detail."
6. **Appointments + visit prep** (`appointment/appointment_detail`) — "Walk in
   ready with the right questions."
7. **Care Circle** (`team/care_team_hub`) — "Invite family to the same plan."
8. **Care summary / emergency card** (`medical/care_summary`) — "Bring a helper
   up to speed in minutes."

---

## 4. Pre-Submission Compliance Checklist

Verify each before submitting to either store. All items reflect shipped
behavior unless marked TODO.

- [ ] **Apple 5.1.1(v) — account deletion.** In-app deletion is shipped at
      **Settings → Delete account** (`SettingsScreen.deleteAccountButtonKey`;
      deletes server-side first, then local). In App Store Connect's review
      notes, point the reviewer to **Settings → Delete account**. Play's Data
      Safety deletion path: same in-app control + support@holdclose.care.
- [ ] **Medical disclaimer present.** The chat carries a persistent, code-side
      line under the composer: *"Coaching support, not medical advice. In an
      emergency, call 911."* (`ChatScreen.disclaimerText`). The Terms +
      Privacy pages restate that Holdclose is **not a medical device** and does
      **not** diagnose, dose, or give prognosis. No symptom checker, no
      diagnosis, no longevity/brain-training claims anywhere in copy.
- [ ] **No LLM vendor/model names in user-facing strings.** Store copy,
      screenshots, and in-app text present a "coach/assistant" — never
      "ChatGPT", "Claude", "GPT", "OpenAI", "Anthropic", "LLM", or "model."
- [ ] **Export compliance.** Holdclose uses only standard encryption
      (HTTPS/TLS in transit via the OS/platform networking stack; no
      proprietary or non-standard cryptography). Declare **exempt** under the
      standard `ITSAppUsesNonExemptEncryption = false` posture; the
      corresponding Play "US export laws" self-classification is the standard
      HTTPS exemption. No custom crypto is bundled.
- [ ] **No government endorsement / affiliation implied.** Copy and metadata
      make no claim of endorsement, certification, or affiliation with any
      government agency, health authority, or clinical body. (Any external
      caregiver-prize materials stay out of the store listing.)
- [ ] **Sign-in providers.** Both **Sign in with Apple** and **Google** ship
      (`sign_in_screen.dart`). Because a third-party/social login (Google) is
      offered, **Sign in with Apple must be present on iOS** — it is. Keep both
      buttons on the iOS build.
- [ ] **Privacy declarations match this doc + the live policy.** App Store
      Privacy labels (Section 1) and Play Data Safety (Section 2) match
      `holdclose.care/privacy`. Re-check after any `legal.ts` change.
- [ ] **No third-party ad/analytics/tracking SDKs.** Confirm none are linked;
      "Used for tracking = No" and "Data sold = No" hold on both forms.
- [ ] **Privacy-policy + terms URLs reachable.** `/privacy` and `/terms` return
      200 on the production Worker before submission (they are public, outside
      the JWT-gated `/api/v1` sub-app).
- [ ] **Children's privacy.** Listing rated for adults; the policy states the
      app is not directed at children under 13.
- [ ] **TODO (operator, pre-submit):** attorney review of Terms + Privacy
      (flagged in `legal.ts`); confirm bundle id / display name are the
      Holdclose values in the release build; ensure the release LLM backend is
      the intended production path (dev uses the local shim).

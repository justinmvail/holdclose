# Claude Project Context — Holdclose (repo still named `careblazers`)

This file is loaded by Claude into context at the start of every session
in this repo.

> **Read this first — the app is mid-rebrand.** The product was
> "Careblazers"; it is being renamed **Holdclose** and repositioned (see
> **Direction** below). The on-disk package is still `careblazers` and the
> code still carries `Careblazers` / `Dr. Natali` / Behavior-Decoder
> naming — that migration is **decided and in progress**, not done. When
> code and docs disagree about *direction*, this file wins; when they
> disagree about *current mechanics*, the code still wins.

## What this is

**Holdclose** is a Flutter mobile app — iOS + Android — that gives family
caregivers an **AI coach that actually knows their loved one's
situation**, wrapped in a full caregiving suite: medications + dose
windows, appointments, a shared Care Circle (server-synced), health log,
emergency card, journal, and a community forum. The unifying wedge is the
**chat coach**, grounded in the loved one's real care data — meds, dose
windows, appointments, history, journal, the care circle — via
`chat_context_builder`. That grounding is the moat: a coach that knows
*your person* beats a blank chatbox (which is why anyone could "just use
the AI"). A Cloudflare Worker backend lives under `backend/`.

The app is **general-purpose caregiving** — for anyone caring for someone
who needs it (aging parents, a disabled family member, post-surgery
recovery, dementia) — **not dementia-only**.

Published under **Juno Code Studio** (JCSV One LLC) at **holdclose.care**.

## Direction (pivot — 2026-06-22; decided, migration in progress)

The product began as "Careblazers," an in-the-moment dementia-behavior
decoder, built as a partnership pitch to Dr. Natali Edmonds (Dementia
Careblazers). **That pitch went unanswered.** The app is being de-branded
and shipped as its own product:

- **Renamed Careblazers → Holdclose** ("hold the people you love close").
  Brand at **holdclose.care**. Code identifiers (`Careblazers*` classes,
  the `careblazers://` deep-link scheme, bundle IDs, `pubspec name:`)
  still say Careblazers — rename is Phase 3.
- **The Behavior Decoder is being removed.** Alpha users found it neat but
  said they'd "just use the chat." The data-grounded chat coach is the
  product now; the decoder is not.
- **All Dr. Natali / Dementia Careblazers framing is being stripped** — no
  attribution, no "Dr. Natali says:", no branded-framework voice.
- **General-purpose, not dementia-specific** — copy + system prompts get
  re-voiced for any care situation.
- **Business model:** paid subscription + a **rev-share affiliate program**
  (per-creator referral codes → commission on *paying* subscribers).
  Needs a paywall (StoreKit / Play Billing) + attribution backend — a
  later phase, gated on Apple/Google **organization** enrollment.

**Migration phases** (these docs describe the target; the code lags it):

1. **Remove the Behavior Decoder** — screens/service/providers/models/
   routes/tests/goldens/seeds; unwire from Home / Journal / Learn /
   onboarding (Journal's `decoder_result_id` link becomes optional).
2. **Re-voice the coach** — strip Natali + dementia-specific framing from
   the system prompts and all copy; broaden to any care situation; refresh
   the seeded loved one to be diagnosis-agnostic.
3. **Rename Careblazers → Holdclose** everywhere — app display name, l10n,
   Dart identifiers, bundle IDs, and the `careblazers://` invite deep-link
   scheme (the last two need **backend coordination** — the Worker mints
   the invite links).

Then, downstream: paywall + affiliate attribution; Apple/Google org
enrollment; store submission.

## Code style

- Flutter 3.x / Dart 3.x. iOS deployment target 16.0; Android API 26+.
- `flutter analyze` clean (warnings allowed; errors not).
- `flutter_riverpod` for state, `go_router` for navigation, `drift` for
  SQLite, `freezed` + `json_serializable` for models,
  `flutter_secure_storage` for auth tokens, `dio` for HTTP, `flutter_tts`
  for OS TTS, `google_fonts` for Lato/Montserrat, `google_sign_in` +
  `sign_in_with_apple` for auth.
- Tests required for every screen + service + provider. Widget tests
  under `test/screens/`, service tests under `test/services/`,
  repository / provider tests under `test/providers/`.
- **Coverage threshold ~80%.** Generated files (`*.g.dart`,
  `*.freezed.dart`, anything under `generated/`) are excluded — strip via
  `lcov --remove` before computing. (The old autoloop "test gate" that
  enforced this automatically is gone; refinement is direct now, so run
  the suite yourself.) New code still needs tests.
- **Every screen needs an alchemist golden.** Goldens live under
  `test/golden/<screen_name>_golden_test.dart` and use
  `goldenTest(...)` with the screen wrapped in a ProviderScope +
  the brand theme. Goldens run as part of `flutter test`.
  Regenerate after intentional visual changes:
  `flutter test --update-goldens test/golden/`.
- Pattern-discovery: read 3 nearby screens or services in the same dir
  before adding code there.
- Don't introduce new state-management libs, routing libs, DB libs,
  or auth libs without updating BUILD_SPEC.md.

## Project layout

(Directory-level map; representative files only. Run `ls` for the full
inventory rather than trusting an inline tree. `screens/decoder/` and the
decoder service/models/seeds are **slated for removal** in Phase 1;
`Careblazers*` identifiers rename in Phase 3.)

```
careblazers/                # repo/package name (renames to holdclose later)
  BUILD_SPEC.md             # original contract — superseded in parts by the pivot; see its top banner
  TASKS.md                  # historical autoloop task queue (do not edit)
  CLAUDE.md / README.md
  pubspec.yaml / l10n.yaml / analysis_options.yaml
  lib/
    main.dart               # bootstrap: preloads, demo reset/seed, sync kick
    app.dart                # MaterialApp.router + deep-link/notification-tap wiring
    theme.dart              # brand tokens (navy #1f2a44, salmon CTA #C97458,
                            # warm white #f8f6f3) via CareblazersColors/context.cb
    routing/router.dart     # go_router: 4-tab StatefulShellRoute + redirects
    l10n/                   # gen-l10n ARB (onboarding screens only so far)
    providers/              # ~42 riverpod providers + backend interfaces
    models/                 # 20 freezed data classes (patient, medication, …)
    services/               # 25 services: chat_service + chat_actions +
                            # chat_context_builder (the data-grounded coach),
                            # sync_service + sync_sink, forum_api_client,
                            # repositories, pdf_exporter, pattern_detector, …
                            # (decoder_service is being removed)
    screens/
      home_screen.dart      # chat-root dashboard (greeting + schedule card)
      decoder/              # behavior_picker, triage, decoder_result — REMOVING
      journal/              # journal, journal_entry, journal_wizard
      medical/              # Care-tab hub: medical_hub, health_log, care_plan, emergency_card
      medication/           # medication_list/form, dose_log, dose_window_list
      appointment/          # appointment list/detail/form
      team/                 # Care Circle hub: care_team_hub, calendar, tasks, shifts, …
      chat/                 # conversation_list, chat_screen (the coach)
      community/            # feed, post detail/compose, learn, support, guidelines
      settings/             # settings, loved_ones
      onboarding/           # welcome_carousel, sign_in, loved_one_setup
    widgets/                # tab_scaffold (4-tab bar + center mic), path_header, …
    db/                     # drift: database.dart (migrations), tables.dart
    seed/                   # seeded loved one, sample data, system prompts,
                            # learn/support/guidelines content (de-Natali in Phase 2)
  test/                     # mirrors lib/: providers/ services/ screens/ … golden/
  integration_test/         # demo_tour.dart, critical_path_smoke_test.dart
  backend/                  # Cloudflare Worker (Hono + drizzle + D1 + R2)
  tools/                    # claude_shim.py, dev_defines, seed/cert scripts
  docs/                     # MENU_LAYOUT_SPEC, CHAT_FEATURE, TTS_BUNDLED
  ios/ android/
```

## Architectural invariants (don't violate)

- **Every backend is behind an interface.** `LLMProvider`,
  `StorageProvider`, `TTSProvider`, `AuthProvider`,
  `AnalyticsProvider` — each is an abstract class with at least two
  implementations (one real, one fake/no-op for tests + demo). The
  app NEVER imports a concrete impl directly; it goes through a
  riverpod provider that wires the impl chosen by build mode.
- **No live LLM calls in `test/`** — use `FakeLLMProvider` with
  canned responses. Live LLM only in `integration_test/demo_tour.dart`
  (against the shim) or in real-app runs.
- **No API keys in source.** The dev backend uses the user's local
  `claude` CLI subscription via `tools/claude_shim.py`. A production
  LLM backend (`ClaudeAPIProvider`) is a later phase.
- **The AI coaching IS the product now (reversal — 2026-06-22).** The old
  rule hid the LLM and presented everything as "Dr. Natali's coaching"
  because the audience was assumed AI-resistant. That's **retired**: the
  Natali framing is gone, and alpha feedback says caregivers *want* the
  smart coach. Present the coach plainly. Two guardrails remain, though:
  (a) **don't expose the vendor/model** — no "ChatGPT", "Claude", "GPT",
  "OpenAI", "Anthropic" in user-facing strings; and (b) the medical
  guardrails below.
- **Medical-advice guardrails are non-negotiable.** The chat carries a
  trusted, code-side disclaimer line under the composer. The LLM system
  prompt explicitly forbids medication dosing recommendations, prognosis
  claims, and "your loved one has X condition" diagnoses. **No symptom
  checker. No diagnosis. No general longevity/brain-training claims.** The
  app coaches the *caregiver*, not the care recipient.
- **Demo mode can reset state on launch; real builds never reset.** In a
  `DEMO_MODE` build, Settings shows a "Reset on launch" toggle (default
  **off**); when on, every cold start wipes + reseeds the demo loved one.
  When off, the demo still backfills a profile if none is on file
  (`ensurePatient`) so dependent screens aren't empty. Non-demo builds
  never render the toggle and never reset. (The seeded loved one becomes
  diagnosis-agnostic in Phase 2.)
- **Security invariants (2026-06-11 hardening — do not regress):**
  - The app NEVER holds a signing secret. Session JWTs are minted by
    the Worker in `POST /auth/google` after Google ID-token
    verification; the client stores the opaque token
    (`ForumSessionManager`) and silently re-exchanges on expiry.
  - Care-circle joins ALWAYS require an explicit in-app confirmation
    (deep link, sign-in replay, and QR scan paths alike). Invites are
    single-use with a 48h TTL.
  - Destructive chat actions (`delete_medication`,
    `cancel_appointment`, `delete_task`) NEVER auto-execute — they
    park as `pending_action:` citations and run only from the
    in-thread confirm card. Voice mode included.
  - Data interpolated into LLM prompts is sanitized + delimited
    (`<current_data>` + fullwidth-bracket substitution in
    `chat_context_builder.dart`); treat any new prompt interpolation
    the same way.
  - Android backups stay OFF (`allowBackup="false"` — the local DB is
    plaintext PHI).
- **Bottom tab bar is always exactly four items in this order —
  Home, Care, Chat, Community — never collapsed or conditionally
  hidden.** ("Medical" was renamed **Care**; the former "Team" tab folded
  into Care as a gated "Care Circle" hub. The Care branch's route path
  stays `/medical` internally and the former team routes stay `/team/*` —
  only the labels + tab structure changed.)
- **Every feature page below a hub uses `PathHeader` with tappable
  breadcrumbs + a back arrow. No screen below a hub relies on the OS
  back button alone.** (`PathHeader.backLabel`/`onBack` params are inert,
  retained for source compatibility.)
- **Maximum two levels deep below a tab landing. Additional depth
  uses in-page tabs / segmented controls, not another tile grid.**

## Common workflows

### Building / running

```bash
flutter pub get
cd ios && pod install && cd ..
flutter run -d <device-id>
flutter test
flutter test integration_test/
flutter analyze
```

### Running the local LLM shim (dev mode)

```bash
# In one terminal:
python3 tools/claude_shim.py
# In another:
flutter run -d <ios-simulator-id>
```

The shim listens on `http://localhost:8765` and shells out to your
local `claude` CLI (uses your Claude Max subscription, zero per-call
cost). `ClaudeCLIProvider` POSTs to it.

### Running the demo tour

```bash
# Demo mode: clean state, deterministic LLM responses (no shim needed;
# chat uses DemoChatBackend)
flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true
```

### Backend (Cloudflare Worker)

```bash
cd backend
npm test              # vitest suite (D1 via wrangler test harness)
npx tsc --noEmit      # type-check
npx drizzle-kit generate --name=<change>   # after editing src/db/schema.ts
# Deploys (operator-run): wrangler deploy + wrangler d1 migrations apply
```

## What NOT to do

- Git actions (commit/push) only when the user asks — run the FULL test
  suite yourself (`flutter analyze` + `flutter test` +
  `cd backend && npm test`) before declaring work done. Refinement is
  direct (the Argus autoloop era is over).
- Don't edit TASKS.md.
- Don't add a new top-level dependency without updating BUILD_SPEC.md.
- Don't make the app talk to `api.anthropic.com` directly in dev — use
  the shim.
- Don't reintroduce **any** Dr. Natali / Dementia Careblazers branding,
  attribution, or copy — the product is its own brand (Holdclose) now.
  And don't embed third-party branded content (audio, course material,
  verbatim site copy) without explicit permission.
- Don't refer to the care recipient as "the patient" in UI copy. Use
  "your loved one" / "your person." (Drop the old "with dementia"
  qualifier — the app is general-purpose now.)
- Don't name the LLM vendor/model ("ChatGPT", "Claude", "GPT", "OpenAI",
  "Anthropic", "LLM", "model") in user-facing strings. Presenting it as a
  smart **coach/assistant** is fine — the *vendor* stays invisible, the
  *capability* no longer does.
- Don't use emojis on primary CTAs. The brand voice doesn't. Emojis are OK
  on content/affordance cards and crisis card sections (📞, ⚠) — not on
  buttons.
- Don't ship default Material colors. The brand tokens in `lib/theme.dart`
  (navy `#1f2a44`, salmon CTA `#C97458`, warm white `#f8f6f3`) override
  every relevant ColorScheme field — reach colors through `context.cb`,
  never raw hex. (Palette carried over from Careblazers; may be revisited
  for the Holdclose brand, but it's the current source of truth.)

## When in doubt

1. Re-read this file's **Direction** section, then `BUILD_SPEC.md` (and
   `docs/MENU_LAYOUT_SPEC.md` for navigation / tab / hub structure) for
   the relevant area — but remember BUILD_SPEC predates the pivot and its
   decoder/Natali/dementia sections are superseded.
2. Read 3 nearby screens or services for patterns.
3. If something is genuinely ambiguous, leave a `// TODO(decision):`
   and continue.

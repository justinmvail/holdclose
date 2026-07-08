# Claude Project Context — Holdclose

This file is loaded by Claude into context at the start of every session
in this repo.

> **Read this first — the rebrand is DONE (2026-06-23, commit `0a27b13`).**
> The product began as "Careblazers"; it is now **Holdclose**. The code is
> fully migrated: the Behavior Decoder is gone, all Dr. Natali / dementia-
> specific framing is stripped, and `Careblazers*` identifiers + the
> `careblazers://` scheme + the `pubspec name:` are renamed to Holdclose
> (`HoldcloseColors`, `context.hc`, `HoldcloseDatabase`, `holdclose://`,
> `package:holdclose/…`, bundle id `com.holdclose.holdclose`). The repo
> directory and GitHub repo were renamed too (2026-07-08): the repo is
> **`/Users/jvail/IdeaProjects/holdclose`**, remote
> **`github.com/justinmvail/holdclose`**. A few internal identifiers are
> **deliberately kept** as `careblazers` and must NOT be "fixed": the
> `careblazers_user_id` D1 column / JSON wire key, the Android
> `namespace` + `com.careblazers.careblazers` Kotlin/JNI package + native
> espeak lib, the `com.careblazers.*` LaunchAgent labels + log filenames
> on the dev Mac, and dev tooling under `tools/`. **BUILD_SPEC.md and
> TASKS.md are stale** on the old framing — when they disagree with the
> code, the code wins.

## What this is

**Holdclose** is a Flutter mobile app — iOS + Android — that gives family
caregivers an **AI coach that actually knows their loved one's
situation**, wrapped in a full caregiving suite: medications + dose
windows, appointments, a shared Care Circle (server-synced), health log,
emergency card, journal, and a community forum — plus a **medical-
coordination layer**: AI scan-to-import for prescriptions, appointment
cards, and insurance cards (each human-approved); AI doctor-visit-prep
questions; AI insurance-appeal letter drafts; NPI provider search (Find a
provider); a shareable care-summary PDF; refill-runway alerts; and
tap-to-call for providers, pharmacy, and insurance. The unifying wedge is the
**chat coach**, grounded in the loved one's real care data — meds, dose
windows, appointments, history, journal, the care circle — via
`chat_context_builder`. That grounding is the moat: a coach that knows
*your person* beats a blank chatbox (which is why anyone could "just use
the AI"). A Cloudflare Worker backend lives under `backend/`.

The app is **general-purpose caregiving** — for anyone caring for someone
who needs it (aging parents, a disabled family member, post-surgery
recovery, dementia) — **not dementia-only**.

Published under **Juno Code Studio** (JCSV One LLC) at **holdclose.care**.

## Direction (pivot — completed 2026-06-23)

The product began as "Careblazers," an in-the-moment dementia-behavior
decoder, built as a partnership pitch to Dr. Natali Edmonds (Dementia
Careblazers). **That pitch went unanswered**, so the app was de-branded and
shipped as its own product, **Holdclose** ("hold the people you love
close"), brand at **holdclose.care**. The three-phase pivot is **done and
pushed** (commit `0a27b13`; all suites green):

1. **Behavior Decoder removed** — screens/service/providers/models/routes/
   tests/goldens/seeds deleted; unwired from Home / Journal / Learn /
   onboarding. `JournalEntry` is now a free-text model (situation /
   attempts / notes / voice / photo); the journal authors entries via the
   wizard + the chat coach's `log_journal` action.
2. **Coach re-voiced general-purpose** — Dr. Natali / Dementia Careblazers
   framing and the dementia-specific "5 Causes" model stripped from the
   chat/voice/recap/title system prompts and all copy; "Careblazer" →
   "caregiver". Dr. Natali's copyrighted Learn videos removed (the Videos
   section hides while empty). The seeded demo person ("Mary Henderson") is
   now diagnosis-agnostic: **post-stroke + hypertension** (Lisinopril /
   Atorvastatin / Aspirin).
3. **Renamed Careblazers → Holdclose** — Dart identifiers, brand strings,
   l10n, `pubspec name:` (`package:holdclose/…`), iOS+Android display name +
   bundle id (`com.holdclose.holdclose`), the `holdclose://` deep-link
   scheme, the `holdclose/tts` method channel, and the backend
   (worker/D1/R2 names, invite HTML). Deliberate keeps (see top banner).

**Operator follow-ups before store/deploy** (breaking, intentional): new
Google OAuth clients for the new bundle id (sign-in breaks otherwise — see
[[google-signin-config]] in memory); testers must reinstall (new bundle id =
fresh app; old `careblazers://` invite links won't open it); create the
Holdclose R2 buckets on deploy (D1 binds by id, so no data migration).

**Business model (still a later phase):** paid subscription + a **rev-share
affiliate program** (per-creator referral codes → commission on *paying*
subscribers). Needs a paywall (StoreKit / Play Billing) + attribution
backend, gated on Apple/Google **organization** enrollment. Then: store
submission.

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
inventory rather than trusting an inline tree.)

```
holdclose/                  # repo root (matches pubspec name:)
  BUILD_SPEC.md             # original contract — superseded in parts by the pivot; see its top banner
  TASKS.md                  # historical autoloop task queue (do not edit)
  CLAUDE.md / README.md
  pubspec.yaml / l10n.yaml / analysis_options.yaml
  lib/
    main.dart               # bootstrap: preloads, demo reset/seed, sync kick
    app.dart                # MaterialApp.router + deep-link/notification-tap wiring
    theme.dart              # brand tokens (navy #1f2a44, salmon CTA #C97458,
                            # warm white #f8f6f3) via HoldcloseColors/context.hc
    routing/router.dart     # go_router: 4-tab StatefulShellRoute + redirects
    l10n/                   # gen-l10n ARB (onboarding screens only so far)
    config/                 # build_info.dart — single source of truth for
                            # version name + per-build stamp (Settings→About)
    providers/              # ~51 riverpod providers + backend interfaces
    models/                 # ~18 freezed data classes (patient, medication, …)
    services/               # ~33 services: chat_service + chat_actions +
                            # chat_context_builder (the data-grounded coach),
                            # sync_service + sync_sink, forum_api_client,
                            # repositories, pdf_exporter, pattern_detector,
                            # the AI scanners (prescription/appointment/
                            # insurance_card + document_scan_transport),
                            # visit_prep, insurance_appeal, npi_provider,
                            # medication_supply (refill runway), …
    screens/
      home_screen.dart      # chat-root dashboard (greeting + schedule card)
      journal/              # journal, journal_entry, journal_wizard
      medical/              # Care-tab hub: medical_hub, health_log, routines,
                            # emergency_card, find_provider, care_summary,
                            # insurance_appeal
      medication/           # medication_list/form, dose_log, dose_window_list,
                            # prescription_scan_flow, medication_import_review
      appointment/          # appointment list/detail/form (+ scan, visit-prep)
      scan_document_screen.dart  # generalized AI document scan entry (/scan)
      team/                 # Care Circle hub: care_team_hub, calendar, tasks, shifts, …
      chat/                 # conversation_list, chat_screen (the coach)
      community/            # feed, post detail/compose, learn, support, guidelines
      settings/             # settings, loved_ones
      onboarding/           # welcome_carousel, sign_in, loved_one_setup
    widgets/                # tab_scaffold (4-tab bar + center mic), path_header, …
    db/                     # drift: database.dart (migrations), tables.dart
    seed/                   # seeded loved one (post-stroke demo persona),
                            # sample data, system prompts, AI extraction
                            # prompts (prescription/appointment/visit-prep/
                            # insurance-appeal/insurance-card), learn/support/
                            # guidelines content (general-purpose, no Natali)
  test/                     # mirrors lib/: providers/ services/ screens/ … golden/
  integration_test/         # demo_tour.dart, critical_path_smoke_test.dart
  backend/                  # Cloudflare Worker (Hono + drizzle + D1 + R2)
  tools/                    # run_device.sh (the device runner) + build_ipa.sh,
                            # claude_shim.py, dev_defines(.example).sh,
                            # seed/cert/tts/espeak scripts, README.md
  caregiver-ai-prize/       # HHS/ACL Caregiver AI Prize packet (task #4)
  feedback/                 # alpha bug-report queue (gitignored; TRIAGE.md)
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
  never render the toggle and never reset. (The seeded loved one is
  diagnosis-agnostic — a post-stroke + hypertension demo persona.)
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

**`tools/run_device.sh` is the ONE device build+install script** (see
`tools/README.md` for the full flag reference). Env-configured:

```bash
flutter pub get
cd ios && pod install && cd ..

tools/run_device.sh                     # AUTH=demo: fake auth, LAN shim, no backend
AUTH=google tools/run_device.sh         # real Google sign-in (ALPHA_AUTH) + backend
AUTH=google SEED=1 tools/run_device.sh  # ...plus a fresh seeded dataset
# knobs: AUTH=demo|google  SEED=1  DEVICE=<id>  SHIM_URL=<url>
# AUTH=google auto-sources tools/dev_defines.sh (Google client ids + backend)

tools/build_ipa.sh                      # release IPA (stamps real CFBundleVersion)

# raw commands still valid:
flutter run -d <device-id>   # simulator/quick fallback (no build-stamp)
flutter test  •  flutter test integration_test/  •  flutter analyze
```

Every `run_device.sh` compile gets a **distinct epoch build number** shown in
**Settings → About** (via `lib/config/build_info.dart`) so a tester can
confirm which binary landed. The report button is always on (`FEEDBACK`).

**Feature flags (`--dart-define`, all default off/empty — scripts set them):**
`DEMO_MODE` (fake auth+seed) · `ALPHA_AUTH` (real Google) · `FEEDBACK` (report
button) — the last two are orthogonal (the old `ALPHA_FEEDBACK` umbrella was
retired). Plus `USE_FAKE_LLM`, `USE_REAL_CAPTURE`, `SHIM_URL`/`SHIM_TOKEN`,
`FORUM_API_URL` (Worker origin; app appends `/api/v1`), `SEED_DEMO`/
`SEED_TOKEN`, `GOOGLE_*_CLIENT_ID`, and the build-stamp defines
(`BUILD_STAMP`/`APP_VERSION`/`GIT_SHA`/`GIT_BRANCH`/`BUILD_TIME`).

### Running the local LLM shim (dev mode)

```bash
# Bind to the LAN so a phone can reach it:
SHIM_HOST=0.0.0.0 SHIM_PORT=8765 python3 tools/claude_shim.py
```

The shim shells out to your local `claude` CLI (zero per-call cost); routes:
`/generate`, `/extract` (image+text scan), `/feedback`, `/phonemize`. The app
reaches it via `SHIM_URL` (LAN, not localhost, on device). The `/extract`
route silently shrinks oversized images — the `claude` CLI drops `@`-mentioned
images over ~200 KB, so scan captures are shrunk client-side too.

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
  every relevant ColorScheme field — reach colors through `context.hc`
  (the `HoldcloseColors` theme extension), never raw hex. (Palette carried
  over from Careblazers; may be revisited for the Holdclose brand, but it's
  the current source of truth.)

## When in doubt

1. Re-read this file's **Direction** section, then `BUILD_SPEC.md` (and
   `docs/MENU_LAYOUT_SPEC.md` for navigation / tab / hub structure) for
   the relevant area — but remember BUILD_SPEC predates the pivot and its
   decoder/Natali/dementia sections are superseded (the code is the truth).
2. Read 3 nearby screens or services for patterns.
3. If something is genuinely ambiguous, leave a `// TODO(decision):`
   and continue.

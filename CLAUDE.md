# Claude Project Context — Careblazers

This file is loaded by Claude into context at the start of every session
in this repo.

## What this is

A Flutter mobile app — iOS + Android — that gives caregivers an
in-the-moment "What do I do RIGHT NOW?" coach for dementia behaviors,
grounded in Dr. Natali Edmonds' (Dementia Careblazers) coaching
framework. The wedge is the **Behavior Decoder**: tap a behavior, answer
three triage questions, get a Dr. Natali–style script with 2–3 things to
say + an environmental tweak + a "don't say" warning. Everything else
in the app (Journal, the Community tab's Learn primers, the Emergency
Card) is a byproduct of repeated decoder use. Since the original spec,
the app has grown a full caregiving suite (medications + dose windows,
appointments, care circle with server sync, community forum, chat
coach with voice intents) and a Cloudflare Worker backend under
`backend/`.

This is the V1 demo build for a pitch to Dr. Natali. Full functional
app — every screen real, every flow live — built first; the demo runs
as an automated `integration_test/` walkthrough over the same code. See
[`BUILD_SPEC.md`](BUILD_SPEC.md) for the contract.

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
- **Coverage threshold is enforced by the autoloop test gate.** 60%
  during tasks 1–4 (scaffold), 80% from task 5 onward. Generated
  files (`*.g.dart`, `*.freezed.dart`, anything under `generated/`)
  are excluded from the count. The gate strips these via `lcov
  --remove` before computing the percentage. New code without
  tests will roll the iter back.
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

(Regenerated 2026-06-11 — directory-level map; representative files only.
Run `ls` for the full inventory rather than trusting an inline tree.)

```
careblazers/
  BUILD_SPEC.md             # the contract (some sections lag the code; code wins)
  TASKS.md                  # autoloop task queue (do not edit)
  CLAUDE.md / README.md
  pubspec.yaml / l10n.yaml / analysis_options.yaml
  lib/
    main.dart               # bootstrap: preloads (onboarding, alpha user,
                            # patient-configured), demo reset/seed, sync kick
    app.dart                # MaterialApp.router + deep-link/notification-tap wiring
    theme.dart              # brand tokens (navy #1f2a44, salmon CTA #C97458,
                            # warm white #f8f6f3) via CareblazersColors/context.cb
    routing/router.dart     # go_router: 4-tab StatefulShellRoute + redirects
    l10n/                   # gen-l10n ARB (onboarding screens only so far)
    providers/              # ~42 riverpod providers + backend interfaces
                            # (llm, storage, tts ×3, auth ×3, analytics,
                            # notifications ×2, capture, settings, sync state,
                            # forum session, quiet hours, patient-configured, …)
    models/                 # 20 freezed data classes (patient, medication,
                            # appointment, chat, forum, document, expense, …)
    services/               # 25 services: chat_service + chat_actions +
                            # chat_context_builder (LLM chat + action tags),
                            # decoder_service, sync_service + sync_sink (outbox
                            # engine), forum_api_client + fake_forum_api_client,
                            # medication/appointment/chat/provider repositories,
                            # pdf_exporter, pattern_detector, feedback_service,
                            # notification_scheduler, circle_deep_link_handler, …
    screens/
      home_screen.dart      # chat-root dashboard (greeting + schedule card)
      decoder/              # behavior_picker, triage, decoder_result (the wedge)
      journal/              # journal, journal_entry, journal_wizard
      medical/              # Care-tab hub: medical_hub, health_log (+form),
                            # care_plan_routines (+form), emergency_card (+edit)
      medication/           # medication_list/form, dose_log, dose_window_list
      appointment/          # appointment list/detail/form
      team/                 # Care Circle hub: care_team_hub, care_circle,
                            # calendar, tasks, shifts, expenses, activity,
                            # circle_qr/scan, username
      chat/                 # conversation_list, chat_screen
      community/            # feed, post detail/compose, learn, support,
                            # guidelines, admin_reports
      settings/             # settings, loved_ones
      onboarding/           # welcome_carousel, sign_in, loved_one_setup
    widgets/                # tab_scaffold (custom 4-tab bar + center mic),
                            # path_header, message_body, caption_fade,
                            # hub_tile, segmented_subnav, voice_button,
                            # home/ (schedule_card, catch_me_up_card, …),
                            # community/, feedback/, form/ (shared form kit)
    db/                     # drift: database.dart (migrations, v20),
                            # tables.dart (+ @TableIndex on hot columns)
    seed/                   # mary_henderson, sample_journal, demo_dataset,
                            # system prompts (system_prompt, chat_system_prompt,
                            # activity_summary_prompt), fake_llm_seeds,
                            # learn/support/guidelines content
  test/                     # mirrors lib/: providers/ services/ screens/
                            # widgets/ db/ routing/ integration/ golden/
  integration_test/         # demo_tour.dart (pitch walkthrough, 4-tab IA),
                            # critical_path_smoke_test.dart
  backend/                  # Cloudflare Worker (Hono + drizzle + D1 + R2):
                            # src/routes/ (auth, circles, join, sync, posts,
                            # comments, votes, profiles, reports, documents),
                            # src/middleware/auth.ts (HS256 session JWTs —
                            # minted SERVER-side in routes/auth.ts),
                            # crisis watchdog, drizzle/ migrations, vitest suite
  tools/
    claude_shim.py          # local HTTP → claude CLI (auth, size caps, watchdog)
    dev_defines.example.sh  # template for tools/dev_defines.sh (gitignored)
    seed_demo.sh / refresh_funnel_cert.sh / vendor_espeak_ng.sh
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
  `claude` CLI subscription via `tools/claude_shim.py`. Production
  backend (`ClaudeAPIProvider`) deferred to a later phase — not in
  v1 demo.
- **No "AI" framing in the UI.** Per dossier analysis, the audience
  is AI-resistant. The product presents "Dr. Natali's coaching" —
  the LLM is invisible. The Settings → About → Methodology disclosure
  AND the "brand & framework credit" card were **removed (2026-06-06,
  user call)** — they felt out of place and the credit's "used with
  permission" line was inaccurate for the pitch build. Settings → About
  now shows only the app version. AI is now mentioned nowhere in the UI;
  if a disclosure is needed later it should live in a privacy/terms doc,
  not a Settings card.
- **Demo mode can reset state on launch; real builds never reset.**
  In a `DEMO_MODE` build, Settings shows a "Reset on launch" toggle
  (default **off** — `AppSettings.defaults().resetOnLaunchDemo ==
  false`); when on, every cold start wipes + reseeds Mary Henderson.
  When off, the demo still backfills Mary's profile if no loved one is
  on file (`ensurePatient`) so patient-dependent screens aren't empty.
  Non-demo builds never render the toggle and never reset. (Wording
  corrected 2026-06-11 to match the code — the old "resets by default"
  phrasing had drifted.)
- **No memory exercises for the patient. No symptom checker.
  No general longevity tips.** Per dossier §7 analysis.
- **Medical-advice guardrails are non-negotiable.** Every decoder
  output includes a footer reminder; the chat screen carries a
  trusted, code-side disclaimer line under the composer. The LLM
  system prompt explicitly forbids medication dosing recommendations,
  prognosis claims, and "your loved one has X condition" diagnoses.
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
  hidden.** (IA refactor 2026-06-06: "Medical" was renamed **Care**;
  the former "Team" tab folded into Care as a gated "Care Circle" hub.
  The Care branch's route path stays `/medical` internally and the
  former team routes stay `/team/*` — only the labels + tab structure
  changed.)
- **Every feature page below a hub uses `PathHeader` with tappable
  breadcrumbs + a back arrow. No screen below a hub relies on the OS
  back button alone.** (The separate word-labeled "Back to X" control
  was removed; `PathHeader.backLabel`/`onBack` params are inert,
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
# chat uses DemoChatBackend, the decoder uses FakeLLMProvider)
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

- Git actions (commit/push) only when the user asks — there is no
  auto gate anymore; run the FULL test suite yourself
  (`flutter analyze` + `flutter test` + `cd backend && npm test`)
  before declaring work done. (Updated 2026-06-11: the Argus autoloop
  era is over; refinement is direct.)
- Don't edit TASKS.md.
- Don't add a new top-level dependency without updating BUILD_SPEC.md.
- Don't make the app talk to `api.anthropic.com` directly in v1 —
  use the shim.
- Don't embed any of Natali's pre-existing branded content (audio
  clips, course material, copy from her site verbatim) into the v1
  build without explicit permission.
- Don't refer to the patient as "the patient" in UI copy. Per
  Natali's vocabulary: "loved one with dementia", "your loved
  one", "your person."
- Don't say "ChatGPT", "Claude", "AI", "LLM", or "model" anywhere
  in user-facing strings. The LLM is invisible.
- Don't use emojis on primary CTAs. The brand voice doesn't.
  Emojis are OK on behavior cards (visual affordances) and crisis
  card sections (📞, ⚠) — not on buttons.
- Don't ship default Material colors. The brand tokens in
  `lib/theme.dart` (navy `#1f2a44`, **salmon CTA `#C97458`** — a
  deliberate rebrand to match careblazers.com, replacing the original
  orange — + warm white `#f8f6f3`) override every relevant
  ColorScheme field. Reach colors through `context.cb`, never raw hex.

## When in doubt

1. Re-read BUILD_SPEC.md (and `docs/MENU_LAYOUT_SPEC.md` for
   navigation / tab / hub structure) for the relevant section.
2. Read 3 nearby screens or services for patterns.
3. If something is genuinely ambiguous, leave a `// TODO(decision):`
   and continue.

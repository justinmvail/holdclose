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
in the app (Journal, Library, Crisis card) is a byproduct of repeated
decoder use.

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

```
careblazers/
  BUILD_SPEC.md
  TASKS.md
  CLAUDE.md
  README.md
  pubspec.yaml
  lib/
    main.dart
    app.dart                # MaterialApp + theme + router
    theme.dart              # brand tokens (navy + orange + Lato/Montserrat)
    routing/
      router.dart           # go_router config
    providers/              # riverpod providers + interfaces
      llm_provider.dart
      storage_provider.dart
      tts_provider.dart
      auth_provider.dart
      analytics_provider.dart
      settings_provider.dart
    models/                 # freezed data classes
      behavior.dart
      triage.dart
      decoder_result.dart
      journal_entry.dart
      patient.dart
      script.dart
      settings.dart
    services/
      decoder_service.dart  # orchestrates LLM + storage
      pattern_detector.dart # flags in journal
      pdf_exporter.dart     # doctor-visit packet
    screens/
      home_screen.dart
      decoder/
        behavior_picker_screen.dart
        triage_screen.dart
        decoder_result_screen.dart
      journal/
        journal_screen.dart
        journal_entry_screen.dart
      medical/
        medical_screen.dart
      team/
        team_screen.dart
      settings/
        settings_screen.dart
      onboarding/
        welcome_carousel.dart
        sign_in_screen.dart
    widgets/                # reusable
      brand_button.dart
      voice_button.dart
      caption_fade.dart
      tab_scaffold.dart
    db/                     # drift database
      database.dart
      tables.dart
    seed/                   # demo seed data
      mary_henderson.dart
      sample_journal.dart
  test/                     # unit + widget tests
    providers/
    services/
    screens/
    widgets/
  integration_test/         # demo automation
    demo_tour.dart
  tools/
    claude_shim.py          # local HTTP → claude CLI
    pdf_template.html       # doctor-visit packet template
  ios/
  android/
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
- **Demo mode resets state on every launch by default.** Settings
  has a toggle to disable that for testing. The real-user app NEVER
  resets — that toggle is hidden behind a debug flag.
- **No memory exercises for the patient. No symptom checker.
  No general longevity tips.** Per dossier §7 analysis.
- **Medical-advice guardrails are non-negotiable.** Every decoder
  output includes a footer reminder. The LLM system prompt
  explicitly forbids medication dosing recommendations, prognosis
  claims, and "your loved one has X condition" diagnoses.
- **Bottom tab bar is always exactly four items in this order —
  Home, Care, Chat, Community — never collapsed or conditionally
  hidden.** (IA refactor 2026-06-06: "Medical" was renamed **Care**;
  the former "Team" tab folded into Care as a gated "Care Circle" hub.
  The Care branch's route path stays `/medical` internally and the
  former team routes stay `/team/*` — only the labels + tab structure
  changed.)
- **Every feature page below a hub uses `PathHeader` with breadcrumb
  + word-labeled Back. No screen below a hub relies on the OS back
  button alone.**
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
# Demo mode: clean state, deterministic LLM responses (no shim needed)
flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true
```

## What NOT to do

- Don't propose any git action — the autoloop handles all git ops.
  Don't run `git commit`, `git push`, etc.
- Don't run the full test suite as part of a task — the autoloop's
  test gate runs after each iter.
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
  `lib/theme.dart` (navy `#1f2a44` + orange `#ff6900` + warm white
  `#f8f6f3`) override every relevant ColorScheme field.

## When in doubt

1. Re-read BUILD_SPEC.md (and `docs/MENU_LAYOUT_SPEC.md` for
   navigation / tab / hub structure) for the relevant section.
2. Read 3 nearby screens or services for patterns.
3. If something is genuinely ambiguous, leave a `// TODO(decision):`
   and continue.

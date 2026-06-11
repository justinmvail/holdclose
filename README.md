# Careblazers

A Flutter mobile app — iOS + Android — that gives caregivers an
in-the-moment "What do I do RIGHT NOW?" coach for dementia behaviors,
grounded in Dr. Natali Edmonds' (Dementia Careblazers) coaching
framework.

This is the **v1 demo build** for a partnership pitch to Dr. Natali.

## Features

- **Behavior Decoder** — the wedge. Tap a behavior, answer three
  triage questions, get a Dr. Natali–style script with 2–3 things to
  say + an environmental tweak + a "don't say" warning. See
  [`BUILD_SPEC.md`](BUILD_SPEC.md) §5.2–§5.4.
- **Chat coach** — multi-turn dementia-care companion for the
  longer-form questions the decoder doesn't fit, with a hands-free
  center-mic voice intent ("log that she didn't sleep") and action
  tags that record meds/doses/appointments/journal entries on the
  caregiver's behalf. Destructive actions (delete/cancel) always go
  through an in-thread confirm card. See
  [`docs/CHAT_FEATURE.md`](docs/CHAT_FEATURE.md).
- **Journal** — auto-fills every time the decoder runs. Pattern
  detector surfaces "3+ falls this week" / similar alerts.
- **Care (hub tab)** — health log, care plan routines, medications +
  dose windows + dose log, appointments, Emergency Card (the
  paramedic/ER handoff sheet), and Cards & Docs scans.
- **Care Circle** — share caregiving across devices: server-backed
  sync (Cloudflare Worker, `backend/`), single-use invite links/QR
  with an explicit join confirmation, shared calendar/tasks/shifts/
  expenses/activity.
- **Community** — caregiver forum (posts, comments, votes,
  moderation, crisis-keyword watchdog) plus the Learn primers and
  Support resources as in-page segments.

## What's in this repo

| File | Purpose |
|---|---|
| [`BUILD_SPEC.md`](BUILD_SPEC.md) | The contract. Every design decision, screen, interface, and acceptance criterion. Read this before any non-trivial change (some sections lag the code; the code wins). |
| [`TASKS.md`](TASKS.md) | Historical autoloop task queue. |
| [`CLAUDE.md`](CLAUDE.md) | Project context loaded by Claude into every session. Code style, layout, invariants. |
| `lib/` | Flutter source. |
| `test/` | Unit + widget + golden tests. Required for every screen, service, provider. |
| `integration_test/demo_tour.dart` | Scripted walkthrough for the Dr. Natali pitch demo (4-tab IA). |
| `backend/` | Cloudflare Worker (Hono + drizzle + D1 + R2): auth, care-circle sync, forum, documents, crisis watchdog. `cd backend && npm test`. |
| `tools/claude_shim.py` | Local HTTP shim that wraps the `claude` CLI for dev-mode LLM calls (bearer auth, size caps, subprocess watchdog). |

## Building

```bash
flutter pub get
cd ios && pod install && cd ..
flutter run -d <ios-simulator-id>
```

## Dev mode (real LLM, local Claude Max subscription)

```bash
# In one terminal:
python3 tools/claude_shim.py     # listens on localhost:8765

# In another:
flutter run -d <simulator-id>
```

The shim uses your local `claude` CLI — zero per-call cost. The Flutter
app's `ClaudeCLIProvider` POSTs to `http://localhost:8765/generate`
and streams the response back.

## Demo tour (automated, no shim needed)

```bash
flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true
```

Uses `FakeLLMProvider` (decoder) + `DemoChatBackend` (chat) for
deterministic, offline responses. Clean state on every launch.

## Audio

The decoder result screen reads scripts aloud via a
bundled on-device neural voice (Piper Amy, ~30 MB, shipped under
`assets/tts/en_US-amy-medium/`). Settings → **High-quality bundled
voice** toggles between that path and the OS engine (`flutter_tts` —
Samantha on iOS, Google TTS on Android). On the rare device where
ONNX Runtime can't load the bundled model, the app transparently
falls back to the OS voice — caregivers never see a broken play
button. See [`docs/TTS_BUNDLED.md`](docs/TTS_BUNDLED.md) for the
full story (catalog swap, latency matrix, failure fallback).

## Tests

```bash
flutter test                          # unit + widget + golden
flutter test integration_test/ --dart-define=DEMO_MODE=true   # end-to-end
flutter analyze                       # static
cd backend && npm test                # Worker vitest suite
```

## What this is NOT

- Not a memory exercise app for the person with dementia
- Not a symptom checker / diagnostic
- Not a general longevity / brain-prevention tool
- Not a replacement for medical care — there are guardrails
  throughout against medication advice, prognosis claims, and
  diagnostic statements

See `BUILD_SPEC.md` §13 for the full risk-and-compliance posture.

## Pitch day checklist

Run through this in order on the demo machine the morning of the
pitch. Don't skip steps — the failure modes are all "obvious in
retrospect."

1. `git pull` latest on `main`.
2. `flutter pub get` — fetches any pinned dep updates.
3. `flutter test` — must be green. If a golden fails, regenerate
   only after confirming the visual change is intentional
   (`flutter test --update-goldens test/golden/`).
4. In one terminal: `SHIM_TOKEN=<token> python3 tools/claude_shim.py`
   — confirm the "listening on localhost:8765" line prints and the
   `claude` CLI is logged in (`claude --version` works). (For a
   fully offline demo, skip the shim and build with
   `--dart-define=USE_FAKE_LLM=true` — decoder AND chat run canned.)
5. In another terminal: `flutter run -d <ios-sim>` — pick the
   demo sim (`flutter devices` to list).
6. Confirm Home renders: greeting + schedule card, Mary Henderson
   seeded as the active loved one, four tabs (Home / Care / Chat /
   Community) with the salmon center mic.
7. Settings → **Reset on launch** is ON (the toggle only appears in
   DEMO_MODE builds; it defaults off). This wipes local data on each
   cold start so the demo always begins from a clean slate.
8. Record a backup video with QuickTime (File → New Movie
   Recording → select the iOS sim). If the live demo wedges,
   you can fall back to the recording without losing the room.

## Status

Pre-pitch. Built for a private partnership conversation with Dr.
Natali Edmonds (Dementia Careblazers). Not yet published. App Store
submission is downstream of the partnership decision.

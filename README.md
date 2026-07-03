# Holdclose

A Flutter mobile app — iOS + Android — that gives family caregivers an
**AI coach that actually knows their loved one's situation**, wrapped in a
full caregiving suite. It works for **any** care situation — aging
parents, a disabled family member, recovery, dementia — not one diagnosis.

> **Repo note:** the package is still named `careblazers` and the code
> still carries `Careblazers` / `Dr. Natali` / Behavior-Decoder naming.
> The app is mid-rebrand to **Holdclose** and is being repositioned — see
> [`CLAUDE.md`](CLAUDE.md) → **Direction** for the pivot and migration
> phases. Published under **Juno Code Studio** at **holdclose.care**.

## Features

- **Chat coach** — the wedge. A multi-turn caregiving companion grounded
  in your loved one's real care data (meds, dose windows, appointments,
  history, journal, the care circle) via `chat_context_builder` — that
  grounding is the point: a coach that knows *your person* beats a blank
  chatbox. Hands-free center-mic voice intent ("log that she didn't
  sleep") and action tags record meds/doses/appointments/journal entries
  on the caregiver's behalf. Destructive actions (delete/cancel) always go
  through an in-thread confirm card. See
  [`docs/CHAT_FEATURE.md`](docs/CHAT_FEATURE.md).
- **Journal** — log moments and outcomes; a pattern detector surfaces
  "3+ falls this week" / similar alerts.
- **Care (hub tab)** — health log, care plan routines, medications + dose
  windows + dose log, appointments, Emergency Card (the paramedic/ER
  handoff sheet), and Cards & Docs scans. Plus a set of medical-
  coordination helpers: **AI scan-to-import** for prescriptions,
  appointments, and insurance cards (always human-approved before it
  writes anything), **AI doctor-visit-prep** questions, **AI insurance-
  appeal** letter drafts, **NPI provider search** (Find a provider), a
  shareable **care-summary PDF**, **refill-runway alerts** (heads-up when
  a med is about to run out), and **tap-to-call** for providers, pharmacy,
  and insurance.
- **Care Circle** — share caregiving across devices: server-backed sync
  (Cloudflare Worker, `backend/`), single-use invite links/QR with an
  explicit join confirmation, shared calendar/tasks/shifts/expenses/
  activity.
- **Community** — caregiver forum (posts, comments, votes, moderation,
  crisis-keyword watchdog) plus Learn primers and Support resources as
  in-page segments.

> The original **Behavior Decoder** (a dementia-behavior triage flow) is
> being removed — alpha users preferred just using the chat. See
> [`CLAUDE.md`](CLAUDE.md).

## What's in this repo

| File | Purpose |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Project context loaded every session. Direction/pivot, code style, layout, invariants. **Start here.** |
| [`BUILD_SPEC.md`](BUILD_SPEC.md) | The original build contract. Comprehensive, but predates the pivot — its Decoder / Dr. Natali / dementia-only sections are superseded (see its top banner). |
| [`TASKS.md`](TASKS.md) | Historical autoloop task queue. |
| `lib/` | Flutter source. |
| `test/` | Unit + widget + golden tests. Required for every screen, service, provider. |
| `integration_test/` | Scripted end-to-end walkthroughs (4-tab IA). |
| `backend/` | Cloudflare Worker (Hono + drizzle + D1 + R2): auth, care-circle sync, forum, documents, crisis watchdog. `cd backend && npm test`. |
| `tools/claude_shim.py` | Local HTTP shim that wraps the `claude` CLI for dev-mode LLM calls (bearer auth, size caps, subprocess watchdog). |

## Building

```bash
flutter pub get
cd ios && pod install && cd ..
```

### Run on a device — `tools/run_device.sh` (primary path)

One env-configured script that builds + installs Holdclose to a device.
Read its header for the full option list; the essentials:

```bash
tools/run_device.sh                       # AUTH=demo (default)
AUTH=google tools/run_device.sh           # real Google sign-in + backend
AUTH=google SEED=1 tools/run_device.sh    # ...plus a fresh seeded dataset
```

- **`AUTH=demo`** (default) — fake auth via `DEMO_MODE`, talks to the LAN
  shim; no backend or Google sign-in needed. Quick dogfooding.
- **`AUTH=google`** — real Google sign-in (`ALPHA_AUTH`) verified by the
  backend; auto-sources `tools/dev_defines.sh` for the Google client ids +
  `FORUM_API_URL` + shim token.
- **`SEED=1`** (optional) — wipe the on-device DB and reseed the
  comprehensive demo dataset on next launch (typically paired with
  `AUTH=google`).
- **`DEVICE=<id>`** / **`SHIM_URL=<url>`** (optional) — override the target
  device or the LLM shim URL.

Every dev build turns on the in-app feedback report button (`FEEDBACK`),
and **every compile gets a distinct build number** (epoch) shown in
Settings → About (via `lib/config/build_info.dart`) so you can confirm
which binary is on the phone. Wireless installs need the phone unlocked +
awake during the whole compile.

For a release IPA whose `CFBundleVersion` also carries that distinct build
number, use **`tools/build_ipa.sh`** (output: `build/ios/ipa/*.ipa`).

Raw commands still work for a simulator fallback or quick checks:

```bash
flutter run -d <device>    # or an <ios-simulator-id>
flutter test
flutter analyze
```

## Dev mode (real LLM, local Claude Max subscription)

```bash
# In one terminal:
python3 tools/claude_shim.py     # listens on localhost:8765

# In another (or just use tools/run_device.sh):
flutter run -d <simulator-id>
```

The shim uses your local `claude` CLI — zero per-call cost. The Flutter
app's `ClaudeCLIProvider` POSTs to `http://localhost:8765/generate`
and streams the response back.

## Demo tour (automated, no shim needed)

```bash
flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true
```

Uses `DemoChatBackend` for deterministic, offline responses. Clean state
on every launch.

## Audio

The app reads coaching replies and content aloud via a bundled on-device
neural voice (Piper Amy, ~30 MB, under `assets/tts/en_US-amy-medium/`).
Settings → **High-quality bundled voice** toggles between that and the OS
engine (`flutter_tts` — Samantha on iOS, Google TTS on Android). Where
ONNX Runtime can't load the bundled model, the app transparently falls
back to the OS voice. See [`docs/TTS_BUNDLED.md`](docs/TTS_BUNDLED.md).

## What this is NOT

- Not a symptom checker / diagnostic
- Not a memory exercise app for the care recipient
- Not a general longevity / brain-prevention tool
- Not a replacement for medical care — there are guardrails throughout
  against medication advice, prognosis claims, and diagnostic statements

## Tests

```bash
flutter test                          # unit + widget + golden
flutter test integration_test/ --dart-define=DEMO_MODE=true   # end-to-end
flutter analyze                       # static
cd backend && npm test                # Worker vitest suite
```

## Status

De-branding from "Careblazers" to **Holdclose** and being prepped as a
standalone product (the original Dr. Natali partnership pitch went
unanswered). Roadmap: remove the Decoder → re-voice the coach for general
caregiving → rename to Holdclose → paywall + affiliate attribution →
Apple/Google **organization** enrollment → store submission. See
[`CLAUDE.md`](CLAUDE.md) → **Direction**.

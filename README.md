# Careblazers

A Flutter mobile app — iOS + Android — that gives caregivers an
in-the-moment "What do I do RIGHT NOW?" coach for dementia behaviors,
grounded in Dr. Natali Edmonds' (Dementia Careblazers) coaching
framework.

This is the **v1 demo build** for a partnership pitch to Dr. Natali.

## What's in this repo

| File | Purpose |
|---|---|
| [`BUILD_SPEC.md`](BUILD_SPEC.md) | The contract. Every design decision, screen, interface, and acceptance criterion. Read this before any non-trivial change. |
| [`TASKS.md`](TASKS.md) | Autoloop task queue. 35+ atomic tasks across 8 phases. |
| [`CLAUDE.md`](CLAUDE.md) | Project context loaded by Claude into every session. Code style, layout, invariants. |
| `lib/` | Flutter source. |
| `test/` | Unit + widget tests. Required for every screen, service, provider. |
| `integration_test/demo_tour.dart` | Scripted walkthrough for the Dr. Natali pitch demo. |
| `tools/claude_shim.py` | Local HTTP shim that wraps the `claude` CLI for dev-mode LLM calls. |

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

Uses `FakeLLMProvider` with deterministic per-behavior responses. Clean
state on every launch.

## Audio

The decoder result screen and library cards read scripts aloud via a
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
flutter test                          # unit + widget
flutter test integration_test/        # end-to-end (uses FakeLLMProvider)
flutter analyze                       # static
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
4. In one terminal: `python3 tools/claude_shim.py` — confirm the
   "listening on localhost:8765" line prints and the `claude` CLI
   is logged in (`claude --version` works).
5. In another terminal: `flutter run -d <ios-sim>` — pick the
   demo sim (`flutter devices` to list).
6. Confirm the home screen renders: navy header, orange "Decode
   a behavior" CTA, Mary Henderson seeded as the active loved
   one.
7. Settings → **Reset on launch** is ON. This wipes the journal
   and decoder history on each cold start so the demo always
   begins from a clean slate.
8. Record a backup video with QuickTime (File → New Movie
   Recording → select the iOS sim). If the live demo wedges,
   you can fall back to the recording without losing the room.

## Status

Pre-pitch. Built for a private partnership conversation with Dr.
Natali Edmonds (Dementia Careblazers). Not yet published. App Store
submission is downstream of the partnership decision.

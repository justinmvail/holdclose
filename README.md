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

## Status

Pre-pitch. Built for a private partnership conversation with Dr.
Natali Edmonds (Dementia Careblazers). Not yet published. App Store
submission is downstream of the partnership decision.

# `tools/` — build, run, and dev scripts

How to build/run Holdclose on a device, every build flag, and where each
piece of configuration lives. **The code is the source of truth**; this file
documents what the scripts and `--dart-define`s actually do.

---

## TL;DR — run it on a device

```bash
# Quick dogfood: fake auth, LAN shim, no backend/Google needed.
tools/run_device.sh

# Real Google sign-in + backend (needs tools/dev_defines.sh):
AUTH=google tools/run_device.sh

# ...plus a fresh comprehensive seeded dataset:
AUTH=google SEED=1 tools/run_device.sh
```

`run_device.sh` is the **one** device build+install script. Every compile
gets a distinct, immutable build number (epoch seconds) shown in **Settings →
About**, and the in-app **feedback report button is always on** for dev
builds.

---

## The scripts

| Script | Purpose |
|---|---|
| **`run_device.sh`** | Build + `flutter run --release` to a device. Env-configured (below). The daily driver. |
| **`build_ipa.sh`** | Release IPA for the store. Unlike `flutter run`, `flutter build` honours `--build-number`, so this bakes the epoch build number into the artifact's real CFBundleVersion / versionCode. |
| **`claude_shim.py`** | Local LLM shim — shells out to your `claude` CLI so dev AI calls cost nothing. Routes: `/generate`, `/extract` (image+text scan), `/feedback`, `/phonemize`. See **The dev LLM shim** below for prereqs + env vars. |
| **`seed_demo.sh`** | *(removed)* — now `AUTH=... SEED=1 tools/run_device.sh`. |
| `regen_tts_samples.sh` | Regenerate bundled-voice sample WAVs (see `docs/TTS_BUNDLED.md`). |
| `refresh_funnel_cert.sh` | Refresh the Tailscale Funnel cert for the dev backend/shim. |
| `record_video_tour.sh` | Screen-record the demo tour. |
| `vendor_espeak_ng.sh` | Re-vendor the native espeak-ng lib. |

### `run_device.sh` configuration (env vars)

| Var | Values | Default | Effect |
|---|---|---|---|
| `AUTH` | `demo` / `google` | `demo` | `demo` = fake auth (`DEMO_MODE`), LAN shim, no backend/Google. `google` = real Google sign-in (`ALPHA_AUTH`), backend-verified; **auto-sources `dev_defines.sh`**, errors if it's missing. |
| `SEED` | `1` / unset | unset | Wipe the on-device DB and reseed the comprehensive ~6-months-back / 1-month-forward dataset once on next launch (`SEED_DEMO`). |
| `DEVICE` | device id | Justin's iPhone (`00008101-001A3C680E81001E`) | `flutter run` target. |
| `SHIM_URL` | URL | funnel URL + `SHIM_TOKEN` from `dev_defines.sh` (both modes; demo falls back to LAN `http://192.168.50.71:8765` only when no `dev_defines.sh` — that needs a scratch shim on `SHIM_HOST=0.0.0.0` and trips iOS's Local Network prompt) | Override the LLM shim. |

Both scripts also derive `APP_VERSION` (name from `pubspec.yaml` + epoch) and
the build-stamp defines (`BUILD_STAMP`, `GIT_SHA`, `GIT_BRANCH`, `BUILD_TIME`)
automatically — you never set those by hand.

> **Wireless gotcha:** keep the iPhone **unlocked and awake** for the whole
> ~70s compile, or the wireless install/launch fails (benign — the app still
> installs; verify with `xcrun devicectl device info apps --device <id>`, or
> `xcrun devicectl device install app --device <id> build/ios/iphoneos/Runner.app`
> and tap the icon). `flutter run` has **no** `--build-number` flag, so
> `devicectl` always shows the pubspec build (24) on a dev run — the *fresh*
> build's identity is the in-app **BUILD_STAMP**, not the iOS version label.

---

## The dev LLM shim (`claude_shim.py`)

```bash
# Purely-local dev (binds 127.0.0.1; endpoints open when no token is set):
python3 tools/claude_shim.py
# Direct-LAN phone access — always set a token when leaving 127.0.0.1:
SHIM_HOST=0.0.0.0 SHIM_TOKEN=<secret> python3 tools/claude_shim.py
```

**Prereqs:** the `claude` CLI installed **and logged in** (verify:
`claude --version`), Python 3.11+. Optional pip deps:
`pip3 install Pillow` — keeps `/extract` scan images under the CLI's
~200 KB attachment ceiling (without it oversized images are *silently
dropped* and the model claims it sees no image); `pip3 install
piper-phonemize` — powers `/phonemize` (returns 501 with an install hint
when missing). Run the shim from the repo root, or `/feedback` reports
land somewhere other than the documented `feedback/` queue.

| Env var | Default | Effect |
|---|---|---|
| `SHIM_HOST` | `127.0.0.1` | Bind address. `0.0.0.0` for direct-LAN phones — token required then. |
| `SHIM_PORT` | `8765` | Listen port. A second instance beside the live one needs a different port. |
| `SHIM_TOKEN` | empty = **open** | Bearer token(s) every request must carry. Comma-separated list = rotation grace window (old + new both accepted while testers update). |
| `SHIM_GENERATE_TIMEOUT` | `180` | Wall-clock watchdog (s) on each `claude` invocation. |
| `FEEDBACK_DIR` | `feedback` | Where `/feedback` reports land — **CWD-relative**. |

### Always-on dev backend (operator's Mac)

On the operator's Mac the tester-facing backend runs permanently via three
user LaunchAgents (`launchctl load -w` / `unload
~/Library/LaunchAgents/<label>.plist`; `launchctl list | grep careblazers`
to see them). The labels + log filenames keep the historical
`careblazers` naming deliberately:

| Label | What it runs | Port → Funnel | Log |
|---|---|---|---|
| `com.careblazers.shim` | `claude_shim.py` (`SHIM_TOKEN` lives in the plist) | 127.0.0.1:8765 → public **:443** | `~/Library/Logs/careblazers-shim.log` |
| `com.careblazers.worker` | `npm run dev` in `backend/` (wrangler dev) | 127.0.0.1:8787 → public **:8443** | `~/Library/Logs/careblazers-worker.log` |
| `com.careblazers.funnelcert` | `refresh_funnel_cert.sh` every 5 min (funnel cert + self-heal) | — | `~/Library/Logs/careblazers-funnel-cert.*.log` |

Consequences: **never** point scratch/test traffic at 8765 or 8787 on this
machine (those are live testers' backends — run scratch instances on other
ports, and give a scratch worker its own `--persist-to` state dir), and
don't hand-restart the shim/worker expecting them to stay down — launchd's
`KeepAlive` respawns them. Public URL + failure modes:
`https://jvails-macbook-pro-2.tailb7b67b.ts.net` (see
`refresh_funnel_cert.sh` for the cert-lapse DNS failure mode).

---

## The feature flags (`--dart-define`s the app reads)

All compile-time, all default off/empty. The scripts set them; you rarely pass
them by hand.

### Mode & auth — **two orthogonal flags**
| Flag | Default | Meaning |
|---|---|---|
| `DEMO_MODE` | false | Fake auth (canned user) + demo seed/reset. Bypasses Google. Read in `settings_provider.dart` + `feedback_service.dart`. |
| `ALPHA_AUTH` | false | Real Google sign-in (`AlphaAuthProvider`), backend-verified. Its own concern — **no** effect on the feedback UI. `auth_provider.dart`. |
| `FEEDBACK` | false | In-app report button + screenshot overlay + raw error detail in chat. Its own concern — **no** effect on auth. `feedback_service.dart`. |

> `ALPHA_FEEDBACK` was retired (2026-07) — it conflated the two above. Use
> `ALPHA_AUTH` and `FEEDBACK` independently.

### LLM / shim
| `SHIM_URL` | `http://localhost:8765` | Where the AI shim lives (`llm_provider.dart`). |
| `SHIM_TOKEN` | `''` | Bearer token baked into the build (must match the shim's). |
| `USE_FAKE_LLM` | false | Canned AI for tests/demo. On a real device the engine defaults to real. |

### Backend / sync
| `FORUM_API_URL` | `''` | Cloudflare Worker origin. Empty = local/demo, no sync. The app appends `/api/v1`. Required for `ALPHA_AUTH` (token verify) + synced Care Circle + the Worker-proxied chat path. |
| `RESYNC_ALL` / `RESYNC_TOKEN` | false/`''` | One-shot re-pull of synced data. |

### Seeding
| `SEED_DEMO` / `SEED_TOKEN` | false/`''` | One-time wipe + comprehensive seed. Seed runs once per distinct token. `main.dart`. |

### Device capture / Google
| `USE_REAL_CAPTURE` | false | Real camera/mic. Auto-on on a physical device. `photo_attacher_provider.dart`. |
| `GOOGLE_SERVER_CLIENT_ID` / `GOOGLE_IOS_CLIENT_ID` | `''` | OAuth client ids for real Google. `auth_provider.dart`. |

### Version / build stamp (script-derived, read via `lib/config/build_info.dart`)
| `BUILD_STAMP` | `dev` | The distinct epoch build number (Settings → About). |
| `APP_VERSION` | `''`→`0.1.0` | `<name>+<build>` for logs/feedback. |
| `GIT_SHA` / `GIT_BRANCH` / `BUILD_TIME` | `''` | The About-screen context line. |

---

## Where configuration lives (5 places)

Most of this is script-derived; you only hand-edit a couple of files.

1. **`tools/run_device.sh`** — the knobs you type (`AUTH`, `SEED`, `DEVICE`,
   `SHIM_URL`). Your main dial; expands into the `--dart-define`s above.
2. **`tools/dev_defines.sh`** *(gitignored — secrets)* — `SHIM_URL`,
   `SHIM_TOKEN`, `FORUM_API_URL`, `GOOGLE_SERVER_CLIENT_ID`,
   `GOOGLE_IOS_CLIENT_ID`. Sourced by `run_device.sh` in `AUTH=google`. Copy
   `dev_defines.example.sh` → `dev_defines.sh` and fill in. *(It also still
   lists `FORUM_JWT_SECRET`, which is **stale** — the app no longer reads it;
   the JWT is minted by the Worker.)*
3. **`pubspec.yaml`** — `version: 0.1.0+N`. The version **name** is the single
   source of truth (`BuildInfo` and the scripts read it).
4. **`ios/Runner/Info.plist`** — the Google reversed-client-id URL scheme
   (`com.googleusercontent.apps.…`). iOS reads this natively at launch, before
   Dart runs — it **cannot** be a `--dart-define`.
5. **Runtime Settings toggles** — not build flags; user-changeable at runtime
   (demo "reset on launch", font size, "Read scripts aloud", bundled voice,
   Care Circle enable).

Layers 3–4 are inherent to how Flutter + iOS work and can't collapse into the
script; that's expected, not a defect.

---

## Common recipes

```bash
# Full test + analyze before a commit
flutter test && flutter analyze

# Demo tour (deterministic, no shim)
flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true

# Rebuild bundled-voice samples
tools/regen_tts_samples.sh ios      # (see docs/TTS_BUNDLED.md)
```

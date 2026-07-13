#!/usr/bin/env bash
#
# tools/run_device.sh — the ONE script that builds + installs Holdclose to a
# device. Configured by env vars; every compile gets a distinct, immutable
# build number (epoch) shown in Settings → About, and the in-app feedback
# report button (FEEDBACK) is always on for dev builds.
#
# Config (all optional):
#   AUTH=demo|google   Default 'demo'.
#                        demo   = fake auth (DEMO_MODE), LAN shim, no backend
#                                 or Google needed — quick dogfooding.
#                        google = real Google sign-in (ALPHA_AUTH), verified by
#                                 the backend. Requires tools/dev_defines.sh
#                                 (Google client ids + Funnel'd FORUM_API_URL +
#                                 shim token) — sourced automatically.
#   SEED=1             Wipe the on-device DB and reseed the comprehensive
#                      ~6-months-back / 1-month-forward dataset once on next
#                      launch (SEED_DEMO). Typically paired with AUTH=google so
#                      a real account has data to explore.
#   DEVICE=<id>        Target device (default: Justin's iPhone, wireless).
#   SHIM_URL=<url>     Override the LLM shim URL (default: LAN in demo mode, or
#                      the dev_defines.sh value in google mode).
#   BACKEND=<env>      Which deployed Worker the build talks to (AUTH=google
#                      only). Compile-time environment selection — one build is
#                      pinned to exactly one backend. One of:
#                        local           = the Tailscale-Funnel'd laptop Worker
#                                          from dev_defines.sh (DEFAULT).
#                        cloudflare-dev  = the deployed edge Worker
#                                          holdclose-forum-dev.jcsvonellc.workers.dev
#                        cloudflare-prod = holdclose.care (once DNS is pointed).
#
# Examples:
#   tools/run_device.sh                       # demo auth, LAN shim (quick)
#   AUTH=google tools/run_device.sh           # real Google auth + laptop backend
#   AUTH=google BACKEND=cloudflare-dev tools/run_device.sh   # → Cloudflare edge deploy
#   AUTH=google SEED=1 tools/run_device.sh    # ...plus a fresh seeded dataset
#
# It BUILDS, INSTALLS, and EXITS — it does not attach to the running app. (It
# used to `exec flutter run`, which never returns; see the note above the build
# step.) CFBundleVersion comes from pubspec's `version:` build number, so BUMP
# THAT when you want a distinguishable install; the epoch BUILD_STAMP shown in
# Settings → About is carried by a dart-define. For a store artifact use
# tools/build_ipa.sh.
#
# ⚠ The phone must be UNLOCKED and awake for the install (a wireless install to
# a locked device fails).
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${DEVICE:-00008101-001A3C680E81001E}"
AUTH="${AUTH:-demo}"

# Distinct + immutable build number per compile.
BUILD_NUMBER="$(date +%s)"
GIT_SHA="$(git rev-parse --short HEAD)"
git diff --quiet || GIT_SHA="${GIT_SHA}+"   # trailing + = uncommitted work
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILD_TIME="$(date -u +'%Y-%m-%d %H:%M UTC')"
APP_NAME="$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//; s/\+.*//')"

# Defines common to every dev build (report button always on).
DEFINES=(
  --dart-define=FEEDBACK=true
  --dart-define=BUILD_STAMP="$BUILD_NUMBER"
  --dart-define=APP_VERSION="${APP_NAME}+${BUILD_NUMBER}"
  --dart-define=GIT_SHA="$GIT_SHA"
  --dart-define=GIT_BRANCH="$GIT_BRANCH"
  --dart-define=BUILD_TIME="$BUILD_TIME"
)

case "$AUTH" in
  google)
    if [[ ! -f tools/dev_defines.sh ]]; then
      echo "error: AUTH=google needs tools/dev_defines.sh (Google client ids +" \
           "FORUM_API_URL + shim token)." >&2
      echo "       cp tools/dev_defines.example.sh tools/dev_defines.sh and fill it in." >&2
      exit 1
    fi
    # shellcheck disable=SC1091
    source tools/dev_defines.sh

    # BACKEND = compile-time environment selection: pin this build to exactly
    # one Worker (no runtime discovery — that would add a single point of
    # failure + a redirect attack surface; Cloudflare's edge already provides
    # the global failover a discovery service would try to fake). 'local' keeps
    # the Funnel'd laptop Worker from dev_defines.sh; the cloudflare-* rows
    # point at deployed Workers. Add a row per new environment.
    BACKEND="${BACKEND:-local}"
    case "$BACKEND" in
      local) : ;;  # keep FORUM_API_URL (+ SHIM_URL) from dev_defines.sh
      cloudflare|cloudflare-dev)
        FORUM_API_URL="https://holdclose-forum-dev.jcsvonellc.workers.dev" ;;
      cloudflare-prod)
        FORUM_API_URL="https://holdclose.care" ;;  # once DNS points at the prod Worker
      *)
        echo "error: unknown BACKEND='$BACKEND'" \
             "(use: local | cloudflare-dev | cloudflare-prod)." >&2
        exit 1 ;;
    esac
    echo "→ backend=${BACKEND}  FORUM_API_URL=${FORUM_API_URL:-<none>}"

    DEFINES+=(
      --dart-define=ALPHA_AUTH=true
      --dart-define=SHIM_URL="${SHIM_URL:-}"
      --dart-define=SHIM_TOKEN="${SHIM_TOKEN:-}"
      --dart-define=FORUM_API_URL="${FORUM_API_URL:-}"
      --dart-define=GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID:-}"
      --dart-define=GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-}"
    )
    ;;
  demo)
    # The live shim binds 127.0.0.1 behind the Tailscale Funnel, so a LAN
    # address is unreachable from a phone (connection refused) AND trips
    # iOS's Local Network permission prompt. Default to the funnel URL +
    # token from dev_defines.sh; the LAN fallback only works against a
    # scratch shim started with SHIM_HOST=0.0.0.0.
    if [[ -z "${SHIM_URL:-}" && -f tools/dev_defines.sh ]]; then
      # shellcheck disable=SC1091
      source tools/dev_defines.sh
    fi
    if [[ -n "${BACKEND:-}" && "${BACKEND}" != "local" ]]; then
      echo "note: BACKEND='${BACKEND}' is ignored in demo mode (no real backend" \
           "or auth); use AUTH=google to hit a deployed Worker." >&2
    fi
    DEFINES+=(
      --dart-define=DEMO_MODE=true
      --dart-define=SHIM_URL="${SHIM_URL:-http://192.168.50.71:8765}"
      --dart-define=SHIM_TOKEN="${SHIM_TOKEN:-}"
    )
    ;;
  *)
    echo "error: AUTH must be 'demo' or 'google' (got '$AUTH')." >&2
    exit 1
    ;;
esac

# Optional wipe + comprehensive reseed on next launch (once per build).
if [[ "${SEED:-}" == "1" ]]; then
  DEFINES+=(
    --dart-define=SEED_DEMO=true
    --dart-define=SEED_TOKEN="$BUILD_NUMBER"
  )
  echo "→ will WIPE + reseed the comprehensive demo dataset on first launch"
fi

echo "→ Holdclose build ${BUILD_NUMBER}  (auth=${AUTH}${SEED:++seed}, ${GIT_BRANCH} @ ${GIT_SHA}, ${BUILD_TIME})"
echo "  device=${DEVICE}"

# BUILD, then INSTALL, then EXIT.
#
# This used to be `exec flutter run --release -d <device>`, which installs the
# app and then STAYS ATTACHED to it forever — it never returns. Every invocation
# left a live process behind: four of them were still running hours later, each
# holding its shell open, so a build that had actually finished in ~2 minutes
# looked like it was "still compiling" for the rest of the day (2026-07-13).
# `flutter run` also swallows the install result behind its own attach/launch
# machinery, which is where the misleading "Error running application" came from
# even on a SUCCESSFUL install.
#
# So: build the .app, install it with devicectl, verify it landed, and return.
flutter build ios --release "${DEFINES[@]}"

APP="build/ios/iphoneos/Runner.app"
if [[ ! -d "$APP" ]]; then
  echo "error: build did not produce $APP" >&2
  exit 1
fi

echo "→ installing to ${DEVICE} (the phone must be UNLOCKED)"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP"; then
  echo "" >&2
  echo "error: install failed. The usual cause is a LOCKED phone —" >&2
  echo "       unlock it, keep it awake, and re-run." >&2
  exit 1
fi

# Prove it actually landed (the version shown is CFBundleVersion, i.e. the
# pubspec build number) rather than trusting the installer's output.
echo "→ installed:"
xcrun devicectl device info apps --device "$DEVICE" 2>/dev/null \
  | grep -i holdclose || {
      echo "warning: could not confirm the app on the device" >&2
    }
echo "→ done. Settings → About shows build stamp ${BUILD_NUMBER}."


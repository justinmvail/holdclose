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
#
# Examples:
#   tools/run_device.sh                       # demo auth, LAN shim (quick)
#   AUTH=google tools/run_device.sh           # real Google auth + backend
#   AUTH=google SEED=1 tools/run_device.sh    # ...plus a fresh seeded dataset
#
# NOTE: `flutter run` has no --build-number flag, so the epoch is carried by
# the BUILD_STAMP dart-define (Settings → About). For a store artifact whose
# CFBundleVersion also carries it, use tools/build_ipa.sh. Wireless installs
# need the phone UNLOCKED + awake during the whole compile.
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
    DEFINES+=(
      --dart-define=DEMO_MODE=true
      --dart-define=SHIM_URL="${SHIM_URL:-http://192.168.50.71:8765}"
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

exec flutter run --release -d "$DEVICE" "${DEFINES[@]}"

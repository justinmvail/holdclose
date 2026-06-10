#!/usr/bin/env bash
#
# tools/seed_demo.sh — wipe the on-device Careblazers database and reseed it
# with a comprehensive ~6-months-back / 1-month-forward test dataset spanning
# EVERY data type (meds + dose history, appointments, health log, care plan,
# journal, care circle, tasks, shifts, expenses, calendar notes, documents,
# chat). Then builds + installs to a device.
#
# Mechanism: the build is stamped with SEED_DEMO=true and a fresh SEED_TOKEN.
# On the next launch the app wipes its database and seeds once, recording the
# token so it never re-wipes on later launches — your edits survive. Rerun
# this script any time you want a fresh dataset.
#
# Usage:
#   tools/seed_demo.sh                 # default device (Justin's iPhone)
#   tools/seed_demo.sh <device-id>     # a specific device / simulator id
#
# Secrets (shim token, forum JWT, Google client ids) are read from an
# untracked tools/dev_defines.sh — copy tools/dev_defines.example.sh to
# tools/dev_defines.sh and fill it in. Without it the app still seeds, but
# chat / forum / Google sign-in won't be wired.
set -euo pipefail

DEVICE="${1:-00008101-001A3C680E81001E}" # default: Justin's iPhone (wireless)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/dev_defines.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/dev_defines.sh"
else
  echo "warning: tools/dev_defines.sh not found — chat/forum/Google won't be" \
       "wired. Copy tools/dev_defines.example.sh to tools/dev_defines.sh." >&2
fi

# A fresh, monotonically-increasing token each run so the seed runs exactly
# once per build (the changing token also makes the compiled binary unique, so
# `flutter run` reinstalls it as new).
TOKEN="$(date +%s)"

echo "Seeding comprehensive demo dataset → device ${DEVICE} (token ${TOKEN})"
echo "The app will WIPE its database and reseed on first launch."

cd "$PROJECT_DIR"
exec flutter run --release -d "$DEVICE" --no-pub \
  --dart-define=SEED_DEMO=true \
  --dart-define=SEED_TOKEN="$TOKEN" \
  --dart-define=BUILD_STAMP="seed-${TOKEN}" \
  --dart-define=ALPHA_FEEDBACK=true \
  --dart-define=SHIM_URL="${SHIM_URL:-}" \
  --dart-define=SHIM_TOKEN="${SHIM_TOKEN:-}" \
  --dart-define=FORUM_API_URL="${FORUM_API_URL:-}" \
  --dart-define=FORUM_JWT_SECRET="${FORUM_JWT_SECRET:-}" \
  --dart-define=GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID:-}" \
  --dart-define=GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-}"

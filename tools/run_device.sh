#!/usr/bin/env bash
#
# Build + install Holdclose to a physical device with a DISTINCT, immutable
# build number on every compile, surfaced in-app under Settings → About.
#
# The build number is epoch seconds (`date +%s`): monotonic, unique per
# compile (two full builds can't finish in the same second), and within
# Android's versionCode int32 ceiling until 2038.
#
# NOTE: `flutter run` has no --build-number flag (only `flutter build` does),
# so on a dev device run the number is carried by the BUILD_STAMP dart-define
# and shown in Settings -> About. That in-app stamp is the tracking id for
# dev builds. For a store artifact whose CFBundleVersion / versionCode also
# carries the number, use tools/build_ipa.sh (there --build-number applies).
# Git sha + UTC time ride along for human tracking either way.
#
# Usage:
#   tools/run_device.sh                 # Justin's iPhone, LAN shim
#   DEVICE=<id> SHIM_URL=<url> tools/run_device.sh
#
# Requires the shim running (SHIM_HOST=0.0.0.0) so the phone can reach it.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${DEVICE:-00008101-001A3C680E81001E}"
SHIM_URL="${SHIM_URL:-http://192.168.50.71:8765}"

BUILD_NUMBER="$(date +%s)"
GIT_SHA="$(git rev-parse --short HEAD)"
git diff --quiet || GIT_SHA="${GIT_SHA}+"   # trailing + flags uncommitted work
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILD_TIME="$(date -u +'%Y-%m-%d %H:%M UTC')"
APP_NAME="$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//; s/\+.*//')"

echo "→ Holdclose build ${BUILD_NUMBER}  (${GIT_BRANCH} @ ${GIT_SHA}, ${BUILD_TIME})"
echo "  device=${DEVICE}  shim=${SHIM_URL}"

exec flutter run --release -d "$DEVICE" \
  --dart-define=DEMO_MODE=true \
  --dart-define=SHIM_URL="$SHIM_URL" \
  --dart-define=BUILD_STAMP="$BUILD_NUMBER" \
  --dart-define=APP_VERSION="${APP_NAME}+${BUILD_NUMBER}" \
  --dart-define=GIT_SHA="$GIT_SHA" \
  --dart-define=GIT_BRANCH="$GIT_BRANCH" \
  --dart-define=BUILD_TIME="$BUILD_TIME"

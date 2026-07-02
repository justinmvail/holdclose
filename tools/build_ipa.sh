#!/usr/bin/env bash
#
# Build a release IPA whose build number is DISTINCT + immutable per compile
# and baked into the artifact's CFBundleVersion (unlike `flutter run`, the
# `flutter build` command honours --build-number). The same epoch number is
# also passed to the display defines so Settings -> About matches the binary.
#
# Usage: tools/build_ipa.sh
# Output: build/ios/ipa/*.ipa
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="$(date +%s)"
GIT_SHA="$(git rev-parse --short HEAD)"
git diff --quiet || GIT_SHA="${GIT_SHA}+"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILD_TIME="$(date -u +'%Y-%m-%d %H:%M UTC')"
APP_NAME="$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//; s/\+.*//')"

echo "→ Holdclose IPA ${APP_NAME}+${BUILD_NUMBER}  (${GIT_BRANCH} @ ${GIT_SHA}, ${BUILD_TIME})"

exec flutter build ipa --release \
  --build-name="$APP_NAME" \
  --build-number="$BUILD_NUMBER" \
  --dart-define=BUILD_STAMP="$BUILD_NUMBER" \
  --dart-define=APP_VERSION="${APP_NAME}+${BUILD_NUMBER}" \
  --dart-define=GIT_SHA="$GIT_SHA" \
  --dart-define=GIT_BRANCH="$GIT_BRANCH" \
  --dart-define=BUILD_TIME="$BUILD_TIME"

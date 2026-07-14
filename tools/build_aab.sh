#!/usr/bin/env bash
#
# Build the SIGNED Android App Bundle for Google Play.
#
# The whole point of this script is the --dart-define set. `flutter build
# appbundle` on its own bakes NONE of them, which produces an app that looks
# fine and is unusable: ALPHA_AUTH is off, so no Google sign-in is wired, and
# FORUM_API_URL is empty, so there is no backend. Every screen in Holdclose sits
# behind the sign-in gate (see holdcloseRedirect in lib/routing/router.dart), so
# a tester of that bundle lands on a sign-in button that cannot complete and
# never reaches the app at all. Not "local-only" — dead.
#
#   tools/build_aab.sh                      # → prod backend (default)
#   BACKEND=cloudflare-dev tools/build_aab.sh   # → the dev Worker
#
# Requires android/key.properties + android/upload-keystore.jks (both gitignored
# — the app never holds a signing secret in source). Without them Gradle falls
# back to DEBUG signing and Play rejects the upload.
#
# What this deliberately does NOT set:
#   * SEED_DEMO / SEED — a seeded build WIPES the database on first launch.
#     Never hand that to anyone holding real care data (docs/DB_FRAGILITY.md).
#   * DEMO_MODE — fake auth, seeded data. Not a store build.
set -euo pipefail

cd "$(dirname "$0")/.."

BACKEND="${BACKEND:-cloudflare-prod}"
case "$BACKEND" in
  cloudflare-prod)
    # The prod Worker's own origin. NOT holdclose.care — no DNS (2026-07-14).
    FORUM_API_URL="https://holdclose-forum.jcsvonellc.workers.dev" ;;
  cloudflare-dev)
    FORUM_API_URL="https://holdclose-forum-dev.jcsvonellc.workers.dev" ;;
  *)
    echo "error: unknown BACKEND='$BACKEND' (use cloudflare-prod | cloudflare-dev)" >&2
    exit 1 ;;
esac

# The Google *Web* client id, passed as serverClientId so the ID token's `aud`
# matches what the Worker checks (GOOGLE_CLIENT_ID in wrangler.toml). Public,
# not a secret. Android does not need its own client id define — Google matches
# the app by package name + signing-certificate SHA-1.
#
# ⚠ Play App Signing RE-SIGNS the upload with Google's own key, so the cert on a
# tester's phone is NOT android/upload-keystore.jks. After the first upload, take
# the SHA-1 from Play Console → App integrity → App signing and add it to the
# Android OAuth client, or every tester's sign-in fails.
GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID:-948989327057-a0o985t2648v1su957ltgohm45i138pb.apps.googleusercontent.com}"

if [[ ! -f android/key.properties ]]; then
  echo "error: android/key.properties missing — Gradle would DEBUG-sign this" >&2
  echo "       bundle and Play would reject it." >&2
  exit 1
fi

BUILD_NUMBER="$(date +%s)"
APP_NAME="$(grep '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f1)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
BUILD_TIME="$(date -u '+%Y-%m-%d %H:%M UTC')"

echo "→ backend=${BACKEND}  FORUM_API_URL=${FORUM_API_URL}"
echo "→ build ${APP_NAME}+${BUILD_NUMBER}  (${GIT_BRANCH} @ ${GIT_SHA})"

flutter build appbundle --release \
  --dart-define=ALPHA_AUTH=true \
  --dart-define=FEEDBACK=true \
  --dart-define=FORUM_API_URL="${FORUM_API_URL}" \
  --dart-define=GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID}" \
  --dart-define=BUILD_STAMP="${BUILD_NUMBER}" \
  --dart-define=APP_VERSION="${APP_NAME}+${BUILD_NUMBER}" \
  --dart-define=GIT_SHA="${GIT_SHA}" \
  --dart-define=GIT_BRANCH="${GIT_BRANCH}" \
  --dart-define=BUILD_TIME="${BUILD_TIME}"

AAB="build/app/outputs/bundle/release/app-release.aab"

# A debug-signed bundle is the failure this script exists to prevent, and Play
# only tells you about it AFTER the upload. Check it here.
OWNER="$(keytool -printcert -jarfile "$AAB" 2>/dev/null | grep -m1 'Owner:' || true)"
if [[ "$OWNER" == *"Android Debug"* || -z "$OWNER" ]]; then
  echo "✗ NOT release-signed: ${OWNER:-<no certificate>}" >&2
  exit 1
fi

echo "→ $AAB"
echo "→ signed: ${OWNER#Owner: }"
echo "→ upload at: Play Console → Test and release → Internal testing"

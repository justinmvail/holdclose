#!/usr/bin/env bash
#
# tools/live_backend_test.sh — run the APP's real networking code against the
# DEPLOYED Cloudflare Worker (test_live/live_backend_test.dart).
#
# This is the only automated test that crosses the app↔backend seam: the widget
# suites fake the client, and backend/test-live drives the Worker over raw
# fetch without touching a line of Dart. The coach's SSE contract lives in that
# gap — see the header of test_live/live_backend_test.dart.
#
# It mints a session JWT signed with the Worker's FORUM_JWT_SECRET (the same
# token POST /auth/google would issue after a real sign-in — the one thing that
# can't be automated, since it needs a Google ID token from the OS sheet), then
# runs the test on the host Dart VM. No device needed.
#
# Config (all optional):
#   BACKEND=cloudflare-dev|local        Which Worker to hit (default: cloudflare-dev).
#   FORUM_API_URL_OVERRIDE=<origin>     Explicit target; wins over BACKEND.
#
# The secret comes from tools/dev_defines.sh (falling back to
# backend/.dev.vars). Refuses to run against production.
#
# NOTE: the test lives in test_live/, NOT integration_test/, for two reasons:
# `flutter test` demands a connected device for anything under
# integration_test/ (this needs none — it's pure Dart + HTTP), and a default
# `flutter test` run only globs test/, so this never fires by accident and
# never spends inference money in CI.
#
# Usage:
#   tools/live_backend_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BACKEND="${BACKEND:-cloudflare-dev}"

# Source the dev defines FIRST (they carry FORUM_JWT_SECRET — and their own
# FORUM_API_URL, which is why the target is resolved afterwards: sourcing
# later would silently clobber the BACKEND choice with the funnel URL).
if [[ -f tools/dev_defines.sh ]]; then
  # shellcheck disable=SC1091
  source tools/dev_defines.sh
fi

if [[ -n "${FORUM_API_URL_OVERRIDE:-}" ]]; then
  FORUM_API_URL="$FORUM_API_URL_OVERRIDE"
else
  case "$BACKEND" in
    cloudflare-dev)
      FORUM_API_URL="https://holdclose-forum-dev.jcsvonellc.workers.dev" ;;
    local) : ;;  # keep the funnel URL that dev_defines.sh just exported
    *) echo "error: unknown BACKEND='$BACKEND' (cloudflare-dev | local)" >&2; exit 1 ;;
  esac
fi

if [[ -z "${FORUM_API_URL:-}" ]]; then
  echo "error: no FORUM_API_URL (set it, or use BACKEND=cloudflare-dev)." >&2
  exit 1
fi

# Never point the suite at production — it creates and deletes real accounts.
if [[ "$FORUM_API_URL" == *"holdclose.care"* ]]; then
  echo "error: refusing to run the live app test against PRODUCTION." >&2
  exit 1
fi

# The Worker verifies session JWTs with FORUM_JWT_SECRET (HS256). We hold the
# dev secret, so we can mint the token sign-in would have produced.
if [[ -z "${FORUM_JWT_SECRET:-}" && -f tools/dev_defines.sh ]]; then
  # shellcheck disable=SC1091
  source tools/dev_defines.sh
fi
if [[ -z "${FORUM_JWT_SECRET:-}" && -f backend/.dev.vars ]]; then
  FORUM_JWT_SECRET="$(grep '^FORUM_JWT_SECRET=' backend/.dev.vars | cut -d= -f2- | tr -d '"' | tr -d "'")"
fi
if [[ -z "${FORUM_JWT_SECRET:-}" ]]; then
  echo "error: FORUM_JWT_SECRET not found (tools/dev_defines.sh or backend/.dev.vars)." >&2
  exit 1
fi

# Mint the session JWT with hono's signer — the exact algorithm + claim shape
# the Worker's auth middleware verifies (sub / iat / exp, HS256). Run from
# backend/, the only place `hono` resolves.
LIVE_JWT="$(
  cd backend && FORUM_JWT_SECRET="$FORUM_JWT_SECRET" node -e "
    const { sign } = require('hono/jwt');
    (async () => {
      const now = Math.floor(Date.now() / 1000);
      // A disposable identity, namespaced so a leaked row is obviously a test's.
      const sub = 'live-app-test-' + Date.now();
      process.stdout.write(
        await sign({ sub, iat: now, exp: now + 3600 }, process.env.FORUM_JWT_SECRET, 'HS256'),
      );
    })();
  "
)"

if [[ -z "$LIVE_JWT" ]]; then
  echo "error: failed to mint the session JWT (run 'npm install' in backend/)." >&2
  exit 1
fi

echo "→ app → ${FORUM_API_URL}  (forged session; makes ONE real inference call)"

exec flutter test test_live/live_backend_test.dart \
  --dart-define=FORUM_API_URL="$FORUM_API_URL" \
  --dart-define=LIVE_JWT="$LIVE_JWT"

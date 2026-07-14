#!/usr/bin/env bash
# Drive EVERY chat action through the LIVE model and the REAL executors.
# The scripted-marker unit tests cannot catch what the model actually writes —
# this is the suite that can. Costs one real inference per action.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f tools/dev_defines.sh ]] && source tools/dev_defines.sh
FORUM_API_URL="${FORUM_API_URL_OVERRIDE:-https://holdclose-forum-dev.jcsvonellc.workers.dev}"
[[ -z "${FORUM_JWT_SECRET:-}" && -f backend/.dev.vars ]] && \
  FORUM_JWT_SECRET="$(grep '^FORUM_JWT_SECRET=' backend/.dev.vars | cut -d= -f2- | tr -d '"')"
LIVE_JWT="$(cd backend && FORUM_JWT_SECRET="$FORUM_JWT_SECRET" node -e "
  const {sign}=require('hono/jwt');
  (async()=>{const n=Math.floor(Date.now()/1000);
   process.stdout.write(await sign({sub:'live-actions-'+n,iat:n,exp:n+3600},process.env.FORUM_JWT_SECRET,'HS256'));})();")"
echo "→ every chat action vs ${FORUM_API_URL}"
exec flutter test test_live/chat_actions_live_test.dart \
  --dart-define=FORUM_API_URL="$FORUM_API_URL" \
  --dart-define=LIVE_JWT="$LIVE_JWT"

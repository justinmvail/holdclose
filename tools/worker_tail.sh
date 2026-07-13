#!/usr/bin/env bash
#
# tools/worker_tail.sh — tail the deployed Worker, showing METHOD, PATH and
# **HTTP STATUS** for every request.
#
# Why this script exists (2026-07-13): `wrangler tail` prints an `outcome`
# field, and `outcome: "ok"` means "the Worker code ran without throwing" — NOT
# "the request succeeded". A tester's phone spent hours getting 401 on EVERY
# authed call while the tail showed a comforting wall of `outcome = ok`, and the
# 401s went unnoticed. Reading `outcome` instead of `status` cost most of a day.
#
# So: this prints the status, first, always. Never eyeball a raw `wrangler tail`
# for request health again — run this.
#
#   tools/worker_tail.sh              # follow (Ctrl-C to stop)
#   tools/worker_tail.sh 120          # follow for 120s, then exit
#   ENV=dev tools/worker_tail.sh      # which wrangler env (default: dev)
#
# Anything that isn't 2xx/3xx is flagged, so a wall of 401s is impossible to
# scroll past.
set -euo pipefail
cd "$(dirname "$0")/../backend"

ENVIRONMENT="${ENV:-dev}"
SECONDS_TO_RUN="${1:-0}"

echo "→ tailing '${ENVIRONMENT}' worker (status-first). Non-2xx/3xx is marked ⚠"

run_tail() {
  npx wrangler tail --env "$ENVIRONMENT" --format json 2>/dev/null
}

if [[ "$SECONDS_TO_RUN" != "0" ]]; then
  run_tail_cmd=(timeout "$SECONDS_TO_RUN" npx wrangler tail --env "$ENVIRONMENT" --format json)
else
  run_tail_cmd=(npx wrangler tail --env "$ENVIRONMENT" --format json)
fi

"${run_tail_cmd[@]}" 2>/dev/null | python3 -u -c '
import json, sys, re

buf = ""
dec = json.JSONDecoder()
for line in sys.stdin:
    buf += re.sub(r"\x1b\[[0-9;]*m", "", line)
    while True:
        start = buf.find("{")
        if start == -1:
            break
        try:
            obj, end = dec.raw_decode(buf, start)
        except ValueError:
            break
        buf = buf[end:]
        req = obj.get("event", {}).get("request", {}) or {}
        resp = obj.get("event", {}).get("response", {}) or {}
        status = resp.get("status")
        method = req.get("method", "")
        url = req.get("url", "")
        path = re.sub(r"^https?://[^/]+", "", url)
        outcome = obj.get("outcome")
        # The whole point: an unhealthy STATUS is impossible to miss, even when
        # the Worker outcome is a cheerful "ok".
        flag = ""
        if status is None:
            flag = "  ⚠ no response"
        elif status >= 400:
            flag = "  ⚠ FAILED"
        shown = str(status) if status is not None else "---"
        print("%4s  %-6s %s%s" % (shown, method, path[:70], flag))
        for e in obj.get("exceptions", []):
            print("      EXC: %s" % str(e.get("message"))[:160])
        for l in obj.get("logs", []):
            print("      LOG: %s" % str(l.get("message"))[:160])
        if outcome not in (None, "ok"):
            print(f"      outcome: {outcome}")
'

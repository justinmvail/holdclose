#!/bin/sh
# Keep the Tailscale Funnel cert fresh + the funnel published, so the
# tester-facing PUBLIC DNS for the shim/worker never silently drops.
#
# Background: when the Funnel TLS cert lapses, Tailscale STOPS publishing the
# public DNS A record for the funnel host — every off-tailnet device (the
# testers' phones) then gets "Failed host lookup" / NXDOMAIN and chat breaks,
# while the laptop keeps working over the tailnet so nothing looks wrong
# locally. (See the careblazers memory "test-server-tailscale-funnel".)
#
# Run daily by ~/Library/LaunchAgents/com.careblazers.funnelcert.plist.
# Idempotent: a no-op when the cert is current and the funnel is already on.

TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
HOST=jvails-macbook-pro-2.tailb7b67b.ts.net
CERTDIR="$HOME/Library/Application Support/careblazers/funnel-cert"
LOG="$HOME/Library/Logs/careblazers-funnel-cert.log"

mkdir -p "$CERTDIR"
cd "$CERTDIR" || exit 1

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
echo "[$(stamp)] refreshing funnel cert + re-asserting funnel for $HOST" >> "$LOG"

# SELF-HEAL: if tailscaled is stopped, the Funnel is silently DOWN for every
# tester — DNS stays published (Tailscale's infra caches it), so it fails as
# a TLS reset rather than an obvious outage, and AI + feedback + sync all die
# at once (the 2026-06-11 outage). Bring it back up before anything else.
# Idempotent: a no-op when already connected.
if "$TS" status 2>&1 | grep -q "Tailscale is stopped"; then
  echo "[$(stamp)] Tailscale was STOPPED — bringing it up" >> "$LOG"
  "$TS" up >> "$LOG" 2>&1
fi

# Re-provision/refresh the cert — this is what re-publishes the public DNS.
"$TS" cert "$HOST" >> "$LOG" 2>&1

# Re-assert both funnels (shim -> 443, worker -> 8443). No-op if already on.
"$TS" funnel --bg 8765 >> "$LOG" 2>&1
"$TS" funnel --bg --https=8443 8787 >> "$LOG" 2>&1

# Sanity-check that the public record is actually PUBLISHED. Query the
# authoritative ts.net nameserver, not a recursive resolver — a recursive
# one (1.1.1.1, etc.) negative-caches a prior NXDOMAIN and would log a false
# "still down" for minutes after the fix.
PUBA="$(dig +short @ns1.dnsimple.com "$HOST" A 2>/dev/null | tr '\n' ' ')"
echo "[$(stamp)] authoritative A: ${PUBA:-<EMPTY — funnel DNS still down!>}" >> "$LOG"

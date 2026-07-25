#!/usr/bin/env bash
# Record the pitch video: run integration_test/video_tour.dart on a
# booted simulator while `simctl recordVideo` captures the screen.
#
# Sync protocol (matches video_tour.dart):
#   1. Launch the tour with SYNC_FILE set; it builds, boots the app,
#      prints VIDEO_TOUR_READY, and idles on the carousel.
#   2. On READY we start the recorder, wait 2s, then create SYNC_FILE —
#      the tour proceeds, so the recording has no build dead-time.
#   3. On VIDEO_TOUR_END we give the final frame a beat and SIGINT the
#      recorder (which finalizes the MP4).
#
# Usage: tools/record_video_tour.sh [simulator-udid]
set -euo pipefail

SIM="${1:-A00DCDD5-063B-43DC-B733-49CB8DE92B9F}"   # iPhone 17 Pro
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/demo_video"
OUT="$OUT_DIR/holdclose_tour_$(date +%Y%m%d_%H%M%S).mp4"
LOG="$OUT_DIR/video_tour_run.log"
SYNC=/tmp/cb_video_sync

mkdir -p "$OUT_DIR"
rm -f "$SYNC"

echo "== Booting simulator $SIM =="
xcrun simctl bootstatus "$SIM" -b
open -a Simulator || true
# Clean marketing status bar for the recording.
xcrun simctl status_bar "$SIM" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 || true

echo "== Building + launching the tour (logs: $LOG) =="
( cd "$ROOT" && flutter test integration_test/video_tour.dart \
    --dart-define=DEMO_MODE=true \
    --dart-define=SYNC_FILE="$SYNC" \
    -d "$SIM" ) >"$LOG" 2>&1 &
TEST_PID=$!

cleanup() {
  xcrun simctl status_bar "$SIM" clear || true
}
trap cleanup EXIT

echo "== Waiting for VIDEO_TOUR_READY (build can take a few minutes) =="
until grep -q VIDEO_TOUR_READY "$LOG" 2>/dev/null; do
  if ! kill -0 "$TEST_PID" 2>/dev/null; then
    echo "!! flutter test exited before READY — see $LOG" >&2
    tail -30 "$LOG" >&2
    exit 1
  fi
  sleep 2
done

echo "== READY — starting recorder =="
xcrun simctl io "$SIM" recordVideo --codec h264 --force "$OUT" &
REC_PID=$!
sleep 2
touch "$SYNC"
echo "== Tour running; waiting for VIDEO_TOUR_END =="

until grep -q VIDEO_TOUR_END "$LOG" 2>/dev/null; do
  if ! kill -0 "$TEST_PID" 2>/dev/null; then
    echo "!! flutter test exited before END — stopping recorder; see $LOG" >&2
    break
  fi
  sleep 2
done

sleep 2
kill -INT "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true

echo "== Done =="
echo "Video:  $OUT"
ls -lh "$OUT" || true
echo "Cue sheet (seconds are relative to recording start, +~2s offset):"
grep VIDEO_CUE "$LOG" || true

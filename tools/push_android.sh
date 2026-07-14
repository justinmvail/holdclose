#!/usr/bin/env bash
#
# Build + install to the Android phone — over Wi-Fi, no cable.
#
#   tools/push_android.sh                 # build arm64 APK, install to the
#                                         # connected device (USB or Wi-Fi)
#   BACKEND=cloudflare-dev tools/push_android.sh
#   CONNECT=192.168.1.42:5555 tools/push_android.sh   # connect first, then push
#
# ONE-TIME wireless setup (Android 11+), no cable needed after this:
#   1. Phone: Settings → System → Developer options → Wireless debugging → ON
#   2. Phone: "Pair device with pairing code" → note the IP:PORT and the 6-digit code
#   3. Mac:   adb pair <IP>:<PAIR_PORT>        # enter the 6-digit code
#   4. Phone: read the IP:PORT shown under "Wireless debugging" (a DIFFERENT port)
#   5. Mac:   adb connect <IP>:<PORT>
#   Then this script works with no cable. Re-run step 5 after a phone reboot.
#
# Why arm64-only: the universal APK is 202 MB (four ABIs); the phone needs one.
# arm64 alone is ~90 MB, which roughly halves the install time on every push.
# The AAB you upload to Play still carries every ABI — Play splits it per device.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "${CONNECT:-}" ]]; then
  echo "→ adb connect ${CONNECT}"
  adb connect "${CONNECT}" >/dev/null || true
fi

DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
if [[ -z "$DEVICE" ]]; then
  echo "error: no Android device. Plug in USB, or set up wireless debugging" >&2
  echo "       (see the header of this script) and re-run with CONNECT=<ip>:<port>" >&2
  exit 1
fi
echo "→ device: $DEVICE"

BACKEND="${BACKEND:-cloudflare-prod}"
case "$BACKEND" in
  cloudflare-prod) FORUM_API_URL="https://holdclose-forum.jcsvonellc.workers.dev" ;;
  cloudflare-dev)  FORUM_API_URL="https://holdclose-forum-dev.jcsvonellc.workers.dev" ;;
  *) echo "error: unknown BACKEND='$BACKEND'" >&2; exit 1 ;;
esac

GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID:-948989327057-a0o985t2648v1su957ltgohm45i138pb.apps.googleusercontent.com}"

BUILD_NUMBER="$(date +%s)"
APP_NAME="$(grep '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f1)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
BUILD_TIME="$(date -u '+%Y-%m-%d %H:%M UTC')"

echo "→ backend=${BACKEND}  build ${APP_NAME}+${BUILD_NUMBER}"

# Same --dart-define set as tools/build_aab.sh. A device test that exercises a
# different build than the one you ship is worth nothing.
flutter build apk --release --target-platform android-arm64 \
  --dart-define=ALPHA_AUTH=true \
  --dart-define=FEEDBACK=true \
  --dart-define=FORUM_API_URL="${FORUM_API_URL}" \
  --dart-define=GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID}" \
  --dart-define=BUILD_STAMP="${BUILD_NUMBER}" \
  --dart-define=APP_VERSION="${APP_NAME}+${BUILD_NUMBER}" \
  --dart-define=GIT_SHA="${GIT_SHA}" \
  --dart-define=GIT_BRANCH="${GIT_BRANCH}" \
  --dart-define=BUILD_TIME="${BUILD_TIME}"

APK="build/app/outputs/flutter-apk/app-release.apk"
echo "→ installing $(du -h "$APK" | cut -f1) to $DEVICE"
adb -s "$DEVICE" install -r "$APK"

adb -s "$DEVICE" shell am start -n \
  com.holdclose.holdclose/com.careblazers.careblazers.MainActivity >/dev/null

echo "→ launched. Settings → About shows build stamp ${BUILD_NUMBER}."

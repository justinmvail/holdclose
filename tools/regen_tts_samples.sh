#!/usr/bin/env bash
#
# Regenerate the Phase 10.4 audio-quality WAV samples for manual
# ear validation. Operator-runnable one-shot, idempotent.
#
# Drives the iOS XCTest (`testRegenerateAudioQualitySamples`) and the
# Android instrumented test (`regenerateAudioQualitySamples`) which
# each synthesise three known scripts through the real espeak-ng
# phonemizer + Piper Amy, then pulls the resulting WAVs into
# `docs/tts_samples/<voice>/{ios,android}/`.
#
# Pre-reqs (one-shot per machine):
#   tools/vendor_espeak_ng.sh
#   cd ios && pod install && cd ..
#   ANDROID_SDK_ROOT or ANDROID_HOME set, adb on PATH for the device pull
#
# Usage:
#   tools/regen_tts_samples.sh                       # both platforms
#   tools/regen_tts_samples.sh ios                   # iOS only
#   tools/regen_tts_samples.sh android               # Android only
#   IOS_SIM="iPhone 16" tools/regen_tts_samples.sh   # override sim
#
# Either platform can be skipped with `--skip-ios` / `--skip-android`
# (so a missing simulator or no plugged-in device doesn't abort the
# other half).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOICE_ID="en_US-amy-medium"
OUT_BASE="${REPO_ROOT}/docs/tts_samples/${VOICE_ID}"

IOS_SIM="${IOS_SIM:-iPhone 16}"
SCRIPT_SLUGS=("decoder_worried" "crisis_card_welcome" "settings_reset_confirmation")

DO_IOS=1
DO_ANDROID=1
case "${1:-both}" in
  ios)
    DO_ANDROID=0 ;;
  android)
    DO_IOS=0 ;;
  both|"")
    ;;
  --skip-ios)
    DO_IOS=0 ;;
  --skip-android)
    DO_ANDROID=0 ;;
  *)
    echo "usage: $0 [ios|android|both|--skip-ios|--skip-android]" >&2
    exit 2 ;;
esac

mkdir -p "${OUT_BASE}/ios" "${OUT_BASE}/android"

if [[ "${DO_IOS}" -eq 1 ]]; then
  echo "[regen] iOS — running XCTest on simulator '${IOS_SIM}'"
  XCODEBUILD_LOG="$(mktemp -t regen-tts-ios.log.XXXXXX)"
  trap 'rm -f "${XCODEBUILD_LOG}"' EXIT

  pushd "${REPO_ROOT}/ios" >/dev/null
  # Filter to just the regen test to avoid the full suite latency.
  xcodebuild test \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -destination "platform=iOS Simulator,name=${IOS_SIM}" \
    -only-testing:RunnerTests/RunnerTests/testRegenerateAudioQualitySamples \
    | tee "${XCODEBUILD_LOG}"
  popd >/dev/null

  # Each PHASE_10_4_REGEN line: "PHASE_10_4_REGEN <slug> <abs-path>".
  # Copy by slug — the XCTest writes into the sim's NSTemporaryDirectory(),
  # which is accessible from the host filesystem on macOS.
  for slug in "${SCRIPT_SLUGS[@]}"; do
    src="$(grep "PHASE_10_4_REGEN ${slug} " "${XCODEBUILD_LOG}" \
           | tail -n1 | awk '{print $3}')"
    if [[ -z "${src}" || ! -f "${src}" ]]; then
      echo "[regen] iOS: WAV for ${slug} not produced (no PHASE_10_4_REGEN log line, or missing file)" >&2
      exit 1
    fi
    cp "${src}" "${OUT_BASE}/ios/${slug}.wav"
    echo "[regen] iOS: ${slug}.wav → ${OUT_BASE}/ios/${slug}.wav"
  done
fi

if [[ "${DO_ANDROID}" -eq 1 ]]; then
  echo "[regen] Android — running instrumented test"
  pushd "${REPO_ROOT}/android" >/dev/null
  ./gradlew :app:connectedDebugAndroidTest \
    -Pandroid.testInstrumentationRunnerArguments.class=\
com.holdclose.holdclose.TTSBridgeInstrumentedTest#regenerateAudioQualitySamples
  popd >/dev/null

  # External app files dir; instrumented test writes here. Path shape:
  # /sdcard/Android/data/com.holdclose.holdclose/files/tts_samples/<voice>/
  REMOTE_BASE="/sdcard/Android/data/com.holdclose.holdclose/files/tts_samples/${VOICE_ID}"
  for slug in "${SCRIPT_SLUGS[@]}"; do
    remote="${REMOTE_BASE}/${slug}.wav"
    if ! adb shell "[ -f ${remote} ]"; then
      echo "[regen] Android: WAV for ${slug} not on device at ${remote}" >&2
      exit 1
    fi
    adb pull "${remote}" "${OUT_BASE}/android/${slug}.wav"
    echo "[regen] Android: ${slug}.wav → ${OUT_BASE}/android/${slug}.wav"
  done
fi

echo "[regen] done."
echo "[regen]   ear-validate:"
for slug in "${SCRIPT_SLUGS[@]}"; do
  echo "[regen]     open ${OUT_BASE}/ios/${slug}.wav ${OUT_BASE}/android/${slug}.wav"
done
echo "[regen]   record verdicts in docs/TTS_BUNDLED.md Phase 10.4 table."

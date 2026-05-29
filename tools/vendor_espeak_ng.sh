#!/usr/bin/env bash
#
# Vendor espeak-ng C sources + runtime data into the iOS Pod tree.
# BUILD_SPEC.md Phase 10.1 — operator-runnable one-shot, idempotent.
#
# Pinned upstream:
#   tag    : 1.52.0
#   commit : 4870adfa25b1a32b4361592f1be8a40337c58d6c
#
# Produces:
#   ios/Vendored/espeak-ng/src/libespeak-ng/      (C sources)
#   ios/Vendored/espeak-ng/src/include/espeak-ng/ (public headers)
#   ios/Vendored/espeak-ng/Resources/espeak-ng-data/ (runtime data)
#   android/app/src/main/cpp/espeak-ng/libespeak-ng/      (C sources, JNI)
#   android/app/src/main/cpp/espeak-ng/include/espeak-ng/ (public headers, JNI)
#   assets/tts/espeak-ng-data/                    (Flutter-bundled mirror)
#
# The Flutter-side mirror is the data dir both bridges resolve at
# runtime: iOS reads it through the CocoaPods resource_bundles path
# (espeak-ng.bundle/espeak-ng-data/), Android reads it through
# AssetManager + a one-time extraction to cacheDir (Phase 10.3, since
# espeak_Initialize wants a filesystem path).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINNED_TAG="1.52.0"
PINNED_COMMIT="4870adfa25b1a32b4361592f1be8a40337c58d6c"
UPSTREAM="https://github.com/espeak-ng/espeak-ng.git"

VENDOR_DIR="${REPO_ROOT}/ios/Vendored/espeak-ng"
ANDROID_DIR="${REPO_ROOT}/android/app/src/main/cpp/espeak-ng"
ASSETS_DIR="${REPO_ROOT}/assets/tts/espeak-ng-data"
SCRATCH="$(mktemp -d -t careblazers-espeak-ng-XXXXXX)"
trap 'rm -rf "${SCRATCH}"' EXIT

echo "[vendor] cloning espeak-ng ${PINNED_TAG} into scratch=${SCRATCH}"
git clone --depth 1 --branch "${PINNED_TAG}" --no-checkout "${UPSTREAM}" "${SCRATCH}/src" >/dev/null 2>&1

cd "${SCRATCH}/src"
git sparse-checkout init --cone >/dev/null
git sparse-checkout set src/libespeak-ng src/include espeak-ng-data >/dev/null
git checkout "${PINNED_TAG}" >/dev/null 2>&1

# Sanity-check the commit hash so a retagged upstream doesn't silently
# substitute a different tree.
ACTUAL_COMMIT="$(git rev-parse HEAD)"
if [[ "${ACTUAL_COMMIT}" != "${PINNED_COMMIT}" ]]; then
  echo "[vendor] ERROR: upstream tag ${PINNED_TAG} resolved to ${ACTUAL_COMMIT}, expected ${PINNED_COMMIT}" >&2
  exit 1
fi

echo "[vendor] copying sources → ${VENDOR_DIR}/src"
rm -rf "${VENDOR_DIR}/src"
mkdir -p "${VENDOR_DIR}/src"
cp -R "${SCRATCH}/src/src/libespeak-ng" "${VENDOR_DIR}/src/libespeak-ng"
cp -R "${SCRATCH}/src/src/include"      "${VENDOR_DIR}/src/include"

echo "[vendor] copying runtime data → ${VENDOR_DIR}/Resources/espeak-ng-data"
rm -rf "${VENDOR_DIR}/Resources"
mkdir -p "${VENDOR_DIR}/Resources"
cp -R "${SCRATCH}/src/espeak-ng-data" "${VENDOR_DIR}/Resources/espeak-ng-data"

# Phase 10.3 Android mirror — the JNI bridge under
# android/app/src/main/cpp/ globs `espeak-ng/libespeak-ng/*.c` through
# CMake. Same upstream tree as iOS so phoneme output stays identical
# across platforms.
echo "[vendor] copying sources → ${ANDROID_DIR}"
rm -rf "${ANDROID_DIR}"
mkdir -p "${ANDROID_DIR}"
cp -R "${SCRATCH}/src/src/libespeak-ng" "${ANDROID_DIR}/libespeak-ng"
cp -R "${SCRATCH}/src/src/include"      "${ANDROID_DIR}/include"

echo "[vendor] mirroring runtime data → ${ASSETS_DIR}"
rm -rf "${ASSETS_DIR}"
mkdir -p "${ASSETS_DIR}"
cp -R "${SCRATCH}/src/espeak-ng-data/." "${ASSETS_DIR}/"

echo "[vendor] done."
echo "[vendor]   iOS:     cd ios && pod install"
echo "[vendor]   Android: rebuild via flutter run -d <android-device>"

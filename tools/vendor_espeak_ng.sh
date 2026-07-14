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
git sparse-checkout set src/libespeak-ng src/include src/ucd-tools src/speechPlayer espeak-ng-data COPYING >/dev/null
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
# ucd-tools: espeak's Unicode character-database helpers. translate.c does
# `#include <ucd/ucd.h>`, so the library does not compile without it.
cp -R "${SCRATCH}/src/src/ucd-tools"    "${VENDOR_DIR}/src/ucd-tools"
# speechPlayer: sPlayer.h includes <speechPlayer.h> unconditionally, even
# though USE_SPEECHPLAYER=0 compiles its code paths out. Headers must exist.
cp -R "${SCRATCH}/src/src/speechPlayer" "${VENDOR_DIR}/src/speechPlayer"

echo "[vendor] copying runtime data → ${VENDOR_DIR}/Resources/espeak-ng-data"
rm -rf "${VENDOR_DIR}/Resources"
mkdir -p "${VENDOR_DIR}/Resources"
cp -R "${SCRATCH}/src/espeak-ng-data" "${VENDOR_DIR}/Resources/espeak-ng-data"

# ---------------------------------------------------------------------------
# The COMPILED runtime data — the part upstream does NOT keep in git.
#
# `espeak-ng-data/` in the repo holds only `lang/` and `voices/` (the human-
# readable definitions). The files espeak_Initialize actually loads —
# phontab, phonindex, phondata, intonations, and the *_dict dictionaries —
# are BUILT by espeak's makefile. Copying the git tree alone yields a data
# directory that looks plausible and initialises to nothing.
#
# That is exactly what shipped: espeak_Initialize failed, TTSBridge fell back
# to its character-by-character phonemizer, and the coach's neural voice spoke
# fluent gibberish on a real phone (2026-07-14). The bridge's fallback is
# silent by design, so the failure had no symptom until someone listened.
#
# Take the compiled data from a LOCAL espeak-ng install whose version matches
# the pin (Homebrew: `brew install espeak-ng`). Version equality is enforced —
# phondata is a binary format tied to its compiler.
# ---------------------------------------------------------------------------
if ! command -v espeak-ng >/dev/null 2>&1; then
  echo "[vendor] ERROR: espeak-ng is not installed locally, so the COMPILED"
  echo "[vendor]        runtime data (phontab/phondata/*_dict) cannot be"
  echo "[vendor]        obtained. Without it the voice speaks gibberish."
  echo "[vendor]        Install the pinned version and re-run:"
  echo "[vendor]            brew install espeak-ng    # must be ${PINNED_TAG}"
  exit 1
fi

LOCAL_VERSION="$(espeak-ng --version | sed -n 's/.*text-to-speech: \([0-9.]*\).*/\1/p')"
if [ "${LOCAL_VERSION}" != "${PINNED_TAG}" ]; then
  echo "[vendor] ERROR: local espeak-ng is ${LOCAL_VERSION}, but this repo pins"
  echo "[vendor]        ${PINNED_TAG}. phondata is a versioned binary format —"
  echo "[vendor]        mixing versions produces wrong phonemes, not an error."
  exit 1
fi

LOCAL_DATA="$(espeak-ng --version | sed -n 's/.*Data at: \(.*\)$/\1/p')"
echo "[vendor] copying COMPILED data ← ${LOCAL_DATA} (espeak-ng ${LOCAL_VERSION})"
for f in phontab phonindex phondata intonations; do
  cp "${LOCAL_DATA}/${f}" "${VENDOR_DIR}/Resources/espeak-ng-data/${f}"
done
cp "${LOCAL_DATA}"/*_dict "${VENDOR_DIR}/Resources/espeak-ng-data/"

# Fail loudly rather than ship a voice that babbles.
for f in phontab phonindex phondata intonations en_dict; do
  if [ ! -f "${VENDOR_DIR}/Resources/espeak-ng-data/${f}" ]; then
    echo "[vendor] ERROR: ${f} missing after copy — espeak would not initialise."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# config.h — espeak's sources `#include "config.h"` unconditionally, but that
# header is produced by autoconf, which we do not run (the Pod compiles the .c
# files directly and passes the handful of knobs as -D flags instead).
#
# So we synthesise a minimal one. It has to live in the vendored tree, and the
# vendored tree is gitignored — which is exactly how the previous copy silently
# disappeared (repo re-clone) and took the build with it. Generating it here
# makes the script self-sufficient: a fresh checkout runs one command and gets
# a compilable, PRONOUNCING espeak.
# ---------------------------------------------------------------------------
write_config_h() {
  cat > "$1/config.h" <<'CONFIG_H'
/* GENERATED by tools/vendor_espeak_ng.sh — do not edit, do not commit.
 * Stand-in for autoconf's config.h; espeak-ng 1.52.0 on iOS/Android. */
#pragma once

#define PACKAGE_VERSION "1.52.0"

/* We drive playback ourselves (AVAudioEngine / AudioTrack); espeak's own
 * threading and audio backends are compiled out. */
#define USE_ASYNC 0
#define USE_LIBPCAUDIO 0
#define HAVE_PCAUDIOLIB_AUDIO_H 0
#define USE_LIBSONIC 0
#define USE_MBROLA 0
#define USE_SPEECHPLAYER 0
#define USE_KLATT 1

/* Platform headers present on both Darwin and Android NDK. */
#define HAVE_STDINT_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STRUCT_TIMESPEC 1
#define HAVE_MKSTEMP 1

/* Endian helpers. espeak's spect.c/phonemelist.c use glibc's le16toh/le32toh,
 * which Darwin does not provide — it spells them OSSwapLittleToHostInt*. Map
 * them here; Android's bionic has <endian.h> and needs no help. */
#if defined(__APPLE__)
#include <libkern/OSByteOrder.h>
#define le16toh(x) OSSwapLittleToHostInt16(x)
#define le32toh(x) OSSwapLittleToHostInt32(x)
#define le64toh(x) OSSwapLittleToHostInt64(x)
#define htole16(x) OSSwapHostToLittleInt16(x)
#define htole32(x) OSSwapHostToLittleInt32(x)
#define htole64(x) OSSwapHostToLittleInt64(x)
#else
#include <endian.h>
#endif
CONFIG_H
}

# The podspec declares a LICENSE file; espeak ships it as COPYING (GPLv3).
cp "${SCRATCH}/src/COPYING" "${VENDOR_DIR}/LICENSE"

echo "[vendor] writing config.h (autoconf stand-in)"
write_config_h "${VENDOR_DIR}/src/libespeak-ng"

# Phase 10.3 Android mirror — the JNI bridge under
# android/app/src/main/cpp/ globs `espeak-ng/libespeak-ng/*.c` through
# CMake. Same upstream tree as iOS so phoneme output stays identical
# across platforms.
echo "[vendor] copying sources → ${ANDROID_DIR}"
rm -rf "${ANDROID_DIR}"
mkdir -p "${ANDROID_DIR}"
cp -R "${SCRATCH}/src/src/libespeak-ng" "${ANDROID_DIR}/libespeak-ng"
cp -R "${SCRATCH}/src/src/include"      "${ANDROID_DIR}/include"
cp -R "${SCRATCH}/src/src/ucd-tools"    "${ANDROID_DIR}/ucd-tools"
cp -R "${SCRATCH}/src/src/speechPlayer" "${ANDROID_DIR}/speechPlayer"
write_config_h "${ANDROID_DIR}/libespeak-ng"

# ---------------------------------------------------------------------------
# The Flutter-asset mirror — ENGLISH ONLY.
#
# Android's bridge loads espeak's data from here (iOS uses the Pod copy). Two
# things forced a pruned mirror:
#
#   * SIZE. The full data set is 24 MB of rules for 100+ languages we do not
#     speak. English-only is 1.2 MB and produces BYTE-IDENTICAL phonemes
#     (verified against the full set, 2026-07-14). On Play, where the base
#     module has a 150 MB ceiling, 23 MB is not a rounding error.
#   * Flutter's asset globs DO NOT RECURSE. Every subdirectory has to be
#     declared in pubspec.yaml by hand, and the full tree has 37 of them. The
#     pruned tree has 3, which is a list a human can keep correct.
#
# en-US is NOT optional: with only `lang/gmw/en` present, espeak silently falls
# back to BRITISH English (dˈɒktə, non-rhotic) and feeds those phonemes to an
# American voice model. No error, just a subtly wrong accent.
# ---------------------------------------------------------------------------
echo "[vendor] mirroring runtime data (English only) → ${ASSETS_DIR}"
rm -rf "${ASSETS_DIR}"
mkdir -p "${ASSETS_DIR}/lang/gmw" "${ASSETS_DIR}/voices/!v"
SRC="${VENDOR_DIR}/Resources/espeak-ng-data"
for f in phontab phonindex phondata intonations en_dict; do
  cp "${SRC}/${f}" "${ASSETS_DIR}/${f}"
done
cp "${SRC}/lang/gmw/en"    "${ASSETS_DIR}/lang/gmw/en"
cp "${SRC}/lang/gmw/en-US" "${ASSETS_DIR}/lang/gmw/en-US"
cp -R "${SRC}/voices/!v/." "${ASSETS_DIR}/voices/!v/"
# The README is the only tracked file in here (the data itself is gitignored).
git -C "${REPO_ROOT}" checkout -- "assets/tts/espeak-ng-data/README.md" 2>/dev/null || true

echo "[vendor] done."
echo "[vendor]   iOS:     cd ios && pod install"
echo "[vendor]   Android: rebuild via flutter run -d <android-device>"

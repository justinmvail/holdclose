#
# BUILD_SPEC.md Phase 10.1 — local CocoaPod that vendors espeak-ng 1.52.0
# for the Runner target. The actual C sources + espeak-ng-data tree are
# pulled by `tools/vendor_espeak_ng.sh` (operator-runnable), which writes
# them into the `src/` and `Resources/espeak-ng-data/` subdirectories
# referenced below. Phase 10.2 calls `espeak_TextToPhonemes` from
# TTSBridge.swift through this pod's bridging-header import.
#
# Why a local pod and not the upstream `espeak-ng-ios` community pod:
# the public pod tracks 1.46.x (last update 2021), predates the 1.52
# IPA-set the bundled Piper Amy voice was trained against, and ships
# without an arm64-simulator slice. The Home Assistant iOS voice
# library vendors espeak-ng the same way — same flags, same data dir
# layout — and that's the reference build we mirror here.
#
# Source provenance:
#   - GitHub: https://github.com/espeak-ng/espeak-ng
#   - Tag:    1.52.0
#   - Commit: 4870adfa25b1a32b4361592f1be8a40337c58d6c
#
# Until `tools/vendor_espeak_ng.sh` lands the sources, this pod
# declares an empty source-file set so `pod install` succeeds in CI /
# fresh checkouts. Phase 10.2's gate is the existence of
# `src/libespeak-ng/speech.c` — if it's missing, the bridging-header
# `__has_include` guard short-circuits and `EspeakNGPhonemizer` falls
# through to its character-lookup path.

Pod::Spec.new do |s|
  s.name             = 'espeak-ng'
  s.version          = '1.52.0'
  s.summary          = 'Vendored espeak-ng for Careblazers iOS TTS phonemizer.'
  s.description      = <<-DESC
    Local pod that builds espeak-ng 1.52.0 as a static library for
    arm64 (device) + arm64-simulator. Consumed by TTSBridge.swift via
    a bridging-header import (`#import <espeak-ng/espeak_ng.h>`).
  DESC
  s.homepage         = 'https://github.com/espeak-ng/espeak-ng'
  s.license          = { :type => 'GPLv3', :file => 'LICENSE' }
  s.author           = { 'Careblazers' => 'team@careblazers.app' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '16.0'
  s.requires_arc     = false

  # Public umbrella header lives at src/include/espeak-ng/{espeak_ng,
  # speak_lib,encoding}.h — those are the three Swift bridges against.
  # Phase 10.2 expands this list if more headers turn out to be needed.
  s.public_header_files = 'src/include/espeak-ng/*.h'

  # The C source tree. `tools/vendor_espeak_ng.sh` sparse-checks out
  # `src/libespeak-ng/` + `src/include/` from the upstream repo. The
  # globs below cover every .c / .h under those trees — espeak-ng's
  # build is monolithic enough that listing individual files is more
  # churn than it's worth.
  s.source_files = [
    'src/libespeak-ng/*.{c,h}',
    'src/include/espeak-ng/*.h',
  ]

  # espeak-ng's runtime data (language rules, phoneme tables,
  # voicedata). `tools/vendor_espeak_ng.sh` copies the `espeak-ng-data`
  # directory from the upstream build artefacts into
  # `Resources/espeak-ng-data/`. CocoaPods bundles it under the
  # `espeak-ng.bundle/` inside the Runner app — TTSBridge.swift
  # resolves the path via `Bundle.main.url(forResource:...)` at
  # `espeak_Initialize` time. Mirror copy lives under
  # `assets/tts/espeak-ng-data/` (Flutter assets) for Phase 10.3 +
  # Android parity; iOS reads from the pod-bundled copy.
  s.resource_bundles = {
    'espeak-ng' => ['Resources/espeak-ng-data/**/*']
  }

  # espeak-ng's build needs a USE_ASYNC=0 (we drive playback ourselves
  # via AVAudioEngine — espeak's internal threading would fight the
  # MethodChannel cancel/restart pattern), HAVE_PCAUDIOLIB=0 (no
  # libpcaudio on iOS), and PACKAGE_VERSION baked in (the autoconf
  # path normally writes this into config.h, which we skip).
  # Reference: Home Assistant iOS voice library's espeak-ng.podspec.
  s.compiler_flags = [
    '-DUSE_ASYNC=0',
    '-DHAVE_PCAUDIOLIB_AUDIO_H=0',
    '-DPACKAGE_VERSION="1.52.0"',
    '-DPATH_ESPEAK_DATA="\"espeak-ng-data\""',
    # espeak-ng's source has a few -Wno worth signposts. Quiet the
    # ones that fire on every Pod build so the Runner log stays
    # readable. None of these mask real bugs — they're all known
    # spelling-of-ancient-C noise.
    '-Wno-unused-parameter',
    '-Wno-unused-but-set-variable',
    '-Wno-shorten-64-to-32',
    '-Wno-format',
  ]

  # Headers live in two places: the public umbrella under
  # `src/include/espeak-ng/` and a handful of private headers
  # alongside the .c files in `src/libespeak-ng/`. Both go on the
  # header search path so the compiler resolves intra-pod `#include`s.
  s.preserve_paths = ['src/include/espeak-ng/*.h', 'src/libespeak-ng/*.h']
  s.xcconfig = {
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/src/include" "${PODS_TARGET_SRCROOT}/src/libespeak-ng"',
    # arm64 simulator slice — onnxruntime-objc ships both arches; the
    # espeak-ng build needs to match so a sim build of Runner doesn't
    # drop the espeak library at link time.
    'VALID_ARCHS' => 'arm64 arm64-simulator x86_64',
    'ENABLE_BITCODE' => 'NO',
  }
end

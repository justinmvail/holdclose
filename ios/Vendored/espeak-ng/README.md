# Vendored espeak-ng

Local CocoaPod that vendors espeak-ng for the Holdclose iOS on-device TTS
bridge. The sources are not committed to this repo;
`tools/vendor_espeak_ng.sh` clones them at the pinned commit on first
setup, and the podspec in this directory wires them into the Runner
build.

## Why local + not the community pod

A public `espeak-ng-ios` Pod exists but tracks espeak-ng 1.46.x (last
updated 2021), missing the 1.52 IPA-set the bundled Piper Amy voice
was trained against. The vendor path also gives us:

- Pinning to a specific commit (no surprise upstream churn).
- arm64-simulator slice control (the public pod ships device-only).
- Build-flag control (Home Assistant's iOS voice library uses a
  specific compile-flag set; we mirror it).

## Layout (after the vendor script runs)

```
ios/Vendored/espeak-ng/
  espeak-ng.podspec        ← committed; references the paths below
  README.md                ← this file
  src/                     ← NOT committed; written by tools/vendor_espeak_ng.sh
    include/
      espeak-ng/
        espeak_ng.h
        speak_lib.h
        encoding.h
    libespeak-ng/
      *.c, *.h             ← ~80 files, ~20 MB
  Resources/
    espeak-ng-data/        ← NOT committed; written by vendor script
      *.dict, *_dict, voices/...   ← ~5 MB language data
```

## Setup (operator, once)

```sh
tools/vendor_espeak_ng.sh
cd ios && pod install
```

The script:

1. Shallow-clones `https://github.com/espeak-ng/espeak-ng` at tag
   `1.52.0` (commit `4870adfa25b1a32b4361592f1be8a40337c58d6c`).
2. Sparse-checks out `src/libespeak-ng/` + `src/include/` + the
   pre-built `espeak-ng-data/` tree.
3. Copies them into the layout above.
4. Removes the clone scratch dir.

After it runs, `pod install` builds the static library and links it
into the Runner target. Phase 10.2 adds the
`#import <espeak-ng/espeak_ng.h>` line to the bridging header and
replaces `EspeakNGPhonemizer`'s character-loop with the real
`espeak_TextToPhonemes` call.

## Why the sources aren't committed

espeak-ng 1.52.0 ships ~20 MB of C sources. Committing them would
bloat the repo by ~10× and force a fork to track every
upstream tag bump. The vendor-script-on-setup pattern follows the
Home Assistant iOS voice library convention and keeps the repo
focused on application code.

CI / fresh checkouts that haven't run the vendor script still build
cleanly: the bridging-header import is guarded with `__has_include`,
and `EspeakNGPhonemizer` falls through to the character-lookup path
documented in Phase 9.3. The XCTest covering the espeak load skips
when the symbols aren't linked.

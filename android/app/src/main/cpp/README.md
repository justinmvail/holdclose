# JNI bridge — careblazers_espeak_ng

BUILD_SPEC.md Phase 10.3 — Android mirror of the iOS Phase 10.1 vendor
drop at `ios/Vendored/espeak-ng/`.

## Layout

```
android/app/src/main/cpp/
  CMakeLists.txt              ← committed; wires the JNI shim + vendored sources
  careblazers_espeak_ng.cpp   ← committed; JNI shim, __has_include guarded
  README.md                   ← this file
  espeak-ng/                  ← NOT committed; written by tools/vendor_espeak_ng.sh
    libespeak-ng/*.c, *.h     ← ~80 files, ~20 MB
    include/espeak-ng/
      espeak_ng.h
      speak_lib.h
      encoding.h
```

The `espeak-ng/` subdirectory is `.gitignore`d for the same reason as
its iOS twin: ~20 MB of upstream C sources don't belong in repo history,
and pinning the SHA in `tools/vendor_espeak_ng.sh` keeps the vendor drop
verifiable on each operator run.

## Setup (operator, once)

```sh
tools/vendor_espeak_ng.sh
flutter build apk --debug   # any flutter build triggers CMake
```

The vendor script populates both `ios/Vendored/espeak-ng/` and this
directory from the same upstream tag (1.52.0, commit
`4870adfa25b1a32b4361592f1be8a40337c58d6c`) so the two bridges stay
phoneme-for-phoneme aligned with the bundled Piper Amy voice.

## Fresh-checkout behavior

Until the vendor script runs, `espeak-ng/libespeak-ng/` is absent.
The CMake `file(GLOB ...)` resolves to an empty source list and the
`#if __has_include(<espeak-ng/espeak_ng.h>)` guard in
`careblazers_espeak_ng.cpp` short-circuits — every native call returns
`-1` / `null` / `false`. The Kotlin side
(`EspeakNGNative.isAvailable()`) reads `false`, and
`EspeakNGPhonemizer` falls through to the Phase 9.4 character-lookup
fallback. The APK still ships
`libcareblazers_espeak_ng.so`; it just doesn't carry espeak-ng.

The autoloop's `flutter test` gate never invokes CMake, so it stays
green on fresh checkouts. The
`TTSBridgeInstrumentedTest.espeakNgVendorLoadsAndPhonemizes` test
skips itself when `nativeHasEspeakNG()` returns false — same skip
semantics as the iOS XCTest counterpart.

## Symbol naming

`careblazers_espeak_ng.cpp` exposes four native methods bound to
`com.careblazers.careblazers.EspeakNGNative` (a Kotlin `object`):

| Native fn               | Returns          | Purpose                                      |
| ----------------------- | ---------------- | -------------------------------------------- |
| `nativeHasEspeakNG`     | `boolean`        | Compile-time flag — true iff sources linked. |
| `nativeInitialize(path)`| `int` (rate / err) | Wraps `espeak_Initialize` + `SetVoiceByName`. |
| `nativeTextToPhonemes`  | `String?` (IPA)  | Loops `espeak_TextToPhonemes` over input.    |
| `nativeTerminate`       | `void`           | Calls `espeak_Terminate`.                    |

Naming follows the standard JNI `Java_<pkg>_<class>_<method>` lookup;
the Kotlin `object` means the JNI signature carries a `jobject` for
the INSTANCE singleton (unused in all four shims).

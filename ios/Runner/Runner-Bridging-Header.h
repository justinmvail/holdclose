#import "GeneratedPluginRegistrant.h"

// BUILD_SPEC.md Phase 10.1 — espeak-ng C-API exposure to Swift.
//
// Imports the vendored espeak-ng umbrella header so TTSBridge.swift
// can call `espeak_Initialize`, `espeak_TextToPhonemes`, and
// `espeak_Terminate` directly. The vendored Pod lives at
// `ios/Vendored/espeak-ng/`; its sources are populated by
// `tools/vendor_espeak_ng.sh`. The `__has_include` guard keeps fresh
// checkouts buildable: until the operator runs the vendor script,
// the symbols aren't linked and `EspeakNGPhonemizer` short-circuits
// to its character-lookup fallback (Phase 9.3's documented behaviour).
// Phase 10.2 lands the actual espeak_TextToPhonemes() call site.
// TWO spellings, because the header's location depends on how the Pod is built:
//   * framework build (use_frameworks!, what we ship) → module `espeak_ng`,
//     headers reachable as <espeak_ng/…>
//   * static-library build                            → <espeak-ng/…>
// Only the hyphenated form was tested here, so on our framework build the guard
// quietly failed, CAREBLAZERS_HAS_ESPEAK_NG became 0, every espeak call site was
// compiled OUT, and the phonemizer fell back to spelling words letter by letter.
// The app built clean and spoke gibberish (2026-07-14).
// Prefer the hyphenated SOURCE headers (the pod puts `src/include` on our header
// search path via `user_target_xcconfig`). They are self-contained — espeak_ng.h
// includes <espeak-ng/speak_lib.h> and defines ESPEAK_NG_API itself. Importing
// the FRAMEWORK module (`espeak_ng`) instead makes Clang build a module whose
// flattened headers can't resolve that same hyphenated include, which fails the
// build outright.
#if __has_include(<espeak-ng/espeak_ng.h>)
#import <espeak-ng/espeak_ng.h>
#import <espeak-ng/speak_lib.h>
#define CAREBLAZERS_HAS_ESPEAK_NG 1
#else
#define CAREBLAZERS_HAS_ESPEAK_NG 0
#endif

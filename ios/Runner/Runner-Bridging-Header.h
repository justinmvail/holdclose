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
#if __has_include(<espeak-ng/espeak_ng.h>)
#import <espeak-ng/espeak_ng.h>
#import <espeak-ng/speak_lib.h>
#define CAREBLAZERS_HAS_ESPEAK_NG 1
#else
#define CAREBLAZERS_HAS_ESPEAK_NG 0
#endif

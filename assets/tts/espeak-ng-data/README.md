# espeak-ng-data (Flutter asset)

Phase 10.1 placeholder. The actual ~5 MB of espeak-ng runtime data
(language rules, phoneme tables, voicedata) is populated by
`tools/vendor_espeak_ng.sh` from upstream espeak-ng 1.52.0
(commit `4870adfa25b1a32b4361592f1be8a40337c58d6c`).

Why both this directory AND
`ios/Vendored/espeak-ng/Resources/espeak-ng-data/` exist:

- The iOS bridge reads from the Pod-bundled copy at
  `Bundle.main.url(forResource: "espeak-ng-data", withExtension: nil,
  subdirectory: "espeak-ng.bundle")` — that's the CocoaPods
  `resource_bundles` convention.
- The Android bridge (Phase 10.3) reads from this Flutter-asset path
  via `AssetManager.open("flutter_assets/assets/tts/espeak-ng-data/
  <file>")`. Android has no CocoaPods analog.
- The vendor script writes both so the two platforms stay in lock-step
  on espeak-ng version.

The directory is empty in fresh checkouts. The autoloop's
`flutter test` gate does not exercise the espeak phonemizer, so an
empty data dir is fine for the gate. Phase 10.2's XCTest covers the
"sources vendored" path; the test skips when the data dir is empty.

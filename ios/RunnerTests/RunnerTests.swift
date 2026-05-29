import Flutter
import UIKit
import XCTest
import onnxruntime_objc
@testable import Runner

// BUILD_SPEC.md Phase 9.3 acceptance: assert the bridge can load the
// bundled voice model and that inference produces non-silent audio.
//
// The .onnx asset is bundled into the Flutter app target, not the
// RunnerTests target — so model-dependent tests skip when the asset
// isn't reachable. The hermetic tests (config parser, phonemizer
// lookup) always run; they cover everything except the ORTSession +
// CoreML pipeline.
class RunnerTests: XCTestCase {

    func testVoiceConfigParsesPiperJson() throws {
        let json = """
        {
          "audio": {"sample_rate": 22050},
          "inference": {
            "noise_scale": 0.667,
            "length_scale": 1.0,
            "noise_w": 0.8
          },
          "phoneme_id_map": {
            "^": [1],
            "$": [2],
            "_": [3],
            "h": [42],
            "e": [17],
            "l": [88],
            "o": [25]
          }
        }
        """.data(using: .utf8)!

        let config = try VoiceConfig.parse(from: json)
        XCTAssertEqual(config.noiseScale, 0.667, accuracy: 1e-6)
        XCTAssertEqual(config.lengthScale, 1.0, accuracy: 1e-6)
        XCTAssertEqual(config.noiseW, 0.8, accuracy: 1e-6)
        XCTAssertEqual(config.phonemeIdMap["h"], [42])
        XCTAssertEqual(config.phonemeIdMap["^"], [1])
    }

    func testPhonemizerEmitsBosEosAndPadPerCharacter() {
        let config = VoiceConfig(
            phonemeIdMap: [
                "^": [1], "$": [2], "_": [0],
                "h": [10], "i": [11],
            ],
            noiseScale: 0.667,
            lengthScale: 1.0,
            noiseW: 0.8
        )
        // Default `useEspeak: false` exercises the character-by-character
        // fallback path documented in Phase 10.1's README — the only path
        // available on a fresh checkout that hasn't run the vendor script.
        let ids = EspeakNGPhonemizer().phonemeIds(for: "hi", config: config)
        // BOS, h, pad, i, pad, EOS
        XCTAssertEqual(ids, [1, 10, 0, 11, 0, 2])
    }

    /// Phase 10.2: the BOS/pad/EOS wrapper is shared between the espeak
    /// and fallback paths. Drive it directly with a fixed token list so
    /// the wrapper invariant is covered even when the espeak symbols
    /// aren't linked.
    func testIdsForTokensWrapsWithBosPadEos() {
        let config = VoiceConfig(
            phonemeIdMap: [
                "^": [1], "$": [2], "_": [0],
                "h": [20], "ə": [27], "l": [24], "o": [25], "ʊ": [50],
            ],
            noiseScale: 0.667,
            lengthScale: 1.0,
            noiseW: 0.8
        )
        let ids = EspeakNGPhonemizer.idsForTokens(
            ["h", "ə", "l", "o", "ʊ"], config: config)
        // BOS, h, pad, ə, pad, l, pad, o, pad, ʊ, pad, EOS
        XCTAssertEqual(ids, [1, 20, 0, 27, 0, 24, 0, 25, 0, 50, 0, 2])
    }

    /// Phase 10.2 acceptance: with the vendored espeak-ng linked,
    /// `EspeakNGPhonemizer(useEspeak: true).phonemeIds(for: "hello world", ...)`
    /// must produce a non-empty ID sequence that differs from the
    /// character-lookup fallback — proves the espeak path actually ran
    /// instead of silently falling through. The phoneme-for-phoneme
    /// exact-match check against Piper's Python `piper-phonemize`
    /// reference impl is captured in `docs/tts_samples/` during Phase
    /// 10.4 manual validation; here we only assert the wiring.
    ///
    /// Skips when `CAREBLAZERS_HAS_ESPEAK_NG` is 0 (no vendored sources)
    /// or when the voice config can't be loaded from the test bundle —
    /// same skip semantics as `testInferenceProducesNonSilentAudio`.
    func testEspeakPhonemizerProducesIpaBackedIdsForHelloWorld() throws {
        #if CAREBLAZERS_HAS_ESPEAK_NG
        let voiceId = "en_US-amy-medium"
        guard let configPath = locateBundleResource(
            name: "\(voiceId).onnx", ext: "json") else {
            throw XCTSkip("\(voiceId).onnx.json not reachable from test bundle — covered by Phase 9.6 device smoke")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try VoiceConfig.parse(from: data)

        // Force an engine init so `espeak_Initialize` runs against the
        // bundled data directory before we ask the phonemizer for IDs.
        _ = TTSEngine()

        let realIds = EspeakNGPhonemizer(useEspeak: true)
            .phonemeIds(for: "hello world", config: config)
        let fallbackIds = EspeakNGPhonemizer(useEspeak: false)
            .phonemeIds(for: "hello world", config: config)

        XCTAssertGreaterThan(realIds.count, 2,
                             "espeak path returned only BOS/EOS — IPA tokens didn't land in the phoneme map")
        XCTAssertEqual(realIds.first, config.phonemeIdMap["^"]?.first,
                       "espeak path didn't prefix BOS")
        XCTAssertEqual(realIds.last, config.phonemeIdMap["$"]?.first,
                       "espeak path didn't suffix EOS")
        XCTAssertNotEqual(realIds, fallbackIds,
                          "espeak path matched the character-lookup fallback — espeak_TextToPhonemes never ran")
        #else
        throw XCTSkip("Vendored espeak-ng not present — run tools/vendor_espeak_ng.sh and `pod install`, then re-run this test")
        #endif
    }

    func testEngineExposesBundledAmyVoice() {
        let voices = TTSEngine().availableVoices()
        XCTAssertEqual(voices.count, 1)
        XCTAssertEqual(voices.first?["id"] as? String, "en_US-amy-medium")
        XCTAssertEqual(voices.first?["locale"] as? String, "en-US")
    }

    /// End-to-end: load the bundled ONNX, run a fixed phoneme array
    /// through `synthesize`, assert the PCM RMS clears zero. Skips
    /// when the .onnx isn't reachable from the test bundle (Phase 9.1
    /// lands the asset under the Flutter app bundle, not the
    /// RunnerTests bundle — Phase 9.6's device smoke covers the real
    /// path).
    func testInferenceProducesNonSilentAudio() throws {
        let voiceId = "en_US-amy-medium"
        guard let modelPath = locateBundleResource(name: voiceId, ext: "onnx"),
              let configPath = locateBundleResource(name: "\(voiceId).onnx", ext: "json") else {
            throw XCTSkip("\(voiceId).onnx not reachable from test bundle — covered by Phase 9.6 device smoke")
        }

        let env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(1)
        let session = try ORTSession(env: env,
                                     modelPath: modelPath,
                                     sessionOptions: opts)
        let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try VoiceConfig.parse(from: configData)

        let phonemeIds = EspeakNGPhonemizer().phonemeIds(for: "hello", config: config)
        XCTAssertFalse(phonemeIds.isEmpty,
                       "phonemizer fell through to empty IDs — config map is missing the test chars")

        let engine = TTSEngine()
        let samples = try engine.synthesize(phonemeIds: phonemeIds,
                                            speed: 1.0,
                                            session: session,
                                            config: config)
        XCTAssertGreaterThan(samples.count, 0, "model returned an empty output tensor")

        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        XCTAssertGreaterThan(rms, 0.0,
                             "inference RMS was zero — model loaded but produced silence")
    }

    private func locateBundleResource(name: String, ext: String) -> String? {
        // Look first in the Flutter-style nested path, then a flat
        // fallback for test fixtures.
        let candidates: [String?] = [
            Bundle.main.path(forResource: name, ofType: ext,
                             inDirectory: "Frameworks/App.framework/flutter_assets/assets/tts/en_US-amy-medium"),
            Bundle.main.path(forResource: name, ofType: ext,
                             inDirectory: "assets/tts/en_US-amy-medium"),
            Bundle.main.path(forResource: name, ofType: ext),
            Bundle(for: type(of: self)).path(forResource: name, ofType: ext),
        ]
        return candidates.compactMap { $0 }.first
    }

    // MARK: Phase 10.1 — espeak-ng vendor smoke

    /// Loads the vendored espeak-ng library, calls
    /// `espeak_TextToPhonemes("hello world")`, and asserts a non-empty
    /// IPA-phoneme string comes back. Smoke-tests the vendor drop —
    /// proves the library links, the data dir resolves, and the
    /// upstream API responds to a trivial call. The phoneme→ID mapping
    /// + tokenizer wiring is Phase 10.2's concern; this test only
    /// covers "the library loads and produces something."
    ///
    /// Skips when `CAREBLAZERS_HAS_ESPEAK_NG` is 0 — that's the state
    /// before `tools/vendor_espeak_ng.sh` runs. Once the vendor script
    /// drops the sources and `pod install` links the library, the
    /// `__has_include` in Runner-Bridging-Header.h flips the flag and
    /// this test starts running for real.
    func testEspeakNgVendorLoadsAndPhonemizes() throws {
        #if CAREBLAZERS_HAS_ESPEAK_NG
        // Resolve the bundled espeak-ng-data path. CocoaPods drops
        // it under espeak-ng.bundle/espeak-ng-data/ in the Runner
        // app; the test bundle inherits the same path via the host
        // app reference.
        let dataPath = locateEspeakDataDirectory()
        guard let dataPathCStr = dataPath?.cString(using: .utf8) else {
            throw XCTSkip("espeak-ng-data not reachable from test bundle — vendor script not yet run, or resource bundle not linked into RunnerTests")
        }

        // espeak_Initialize signature: (output mode, buflength, path, options).
        // AUDIO_OUTPUT_SYNCHRONOUS=2; we discard audio in this test.
        let rate = espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, dataPathCStr, 0)
        XCTAssertGreaterThan(rate, 0,
                             "espeak_Initialize returned non-positive sample rate — data path malformed or library mis-linked")
        defer { espeak_Terminate() }

        // espeak_SetVoiceByName accepts "en-us" out of the box once
        // the data dir is reachable.
        let voiceResult = espeak_SetVoiceByName("en-us")
        XCTAssertEqual(voiceResult, EE_OK,
                       "espeak_SetVoiceByName failed for en-us — voicedata missing under espeak-ng-data/voices/")

        // espeak_TextToPhonemes consumes a `const void **` pointer to
        // the text and advances it. We pass IPA (phonememode=0x02)
        // with a separator of 0 (no separator), output as a single
        // string of Unicode IPA characters.
        var text = "hello world".cString(using: .utf8)!
        let phonemes: UnsafePointer<CChar>? = text.withUnsafeMutableBufferPointer { buf -> UnsafePointer<CChar>? in
            var textPtr: UnsafeRawPointer? = UnsafeRawPointer(buf.baseAddress)
            return espeak_TextToPhonemes(&textPtr, espeakCHARS_UTF8, 0x02)
        }
        XCTAssertNotNil(phonemes, "espeak_TextToPhonemes returned NULL")
        let ipa = phonemes.flatMap { String(cString: $0) } ?? ""
        XCTAssertFalse(ipa.isEmpty,
                       "espeak_TextToPhonemes returned an empty string for 'hello world'")
        #else
        throw XCTSkip("Vendored espeak-ng not present — run tools/vendor_espeak_ng.sh and `pod install`, then re-run this test")
        #endif
    }

    /// Locate the espeak-ng-data directory. CocoaPods `resource_bundles`
    /// drops it under `Bundle.main.url(forResource: "espeak-ng",
    /// withExtension: "bundle")/espeak-ng-data/`. Fallback candidates
    /// cover the Flutter-asset mirror path and a flat test-bundle
    /// layout for hermetic runs.
    private func locateEspeakDataDirectory() -> String? {
        let mainBundle = Bundle.main
        let candidates: [String?] = [
            mainBundle.url(forResource: "espeak-ng", withExtension: "bundle")?
                .appendingPathComponent("espeak-ng-data").path,
            mainBundle.path(forResource: "espeak-ng-data", ofType: nil,
                            inDirectory: "Frameworks/App.framework/flutter_assets/assets/tts"),
            mainBundle.path(forResource: "espeak-ng-data", ofType: nil),
            Bundle(for: type(of: self)).path(forResource: "espeak-ng-data", ofType: nil),
        ]
        return candidates.compactMap { $0 }.first
    }
}

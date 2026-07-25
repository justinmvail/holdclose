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
    /// Skips when `HOLDCLOSE_HAS_ESPEAK_NG` is 0 (no vendored sources)
    /// or when the voice config can't be loaded from the test bundle —
    /// same skip semantics as `testInferenceProducesNonSilentAudio`.
    func testEspeakPhonemizerProducesIpaBackedIdsForHelloWorld() throws {
        #if HOLDCLOSE_HAS_ESPEAK_NG
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
    /// Skips when `HOLDCLOSE_HAS_ESPEAK_NG` is 0 — that's the state
    /// before `tools/vendor_espeak_ng.sh` runs. Once the vendor script
    /// drops the sources and `pod install` links the library, the
    /// `__has_include` in Runner-Bridging-Header.h flips the flag and
    /// this test starts running for real.
    func testEspeakNgVendorLoadsAndPhonemizes() throws {
        #if HOLDCLOSE_HAS_ESPEAK_NG
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

    // MARK: Phase 10.4 — audio-quality sample regen

    /// Renders the three Phase 10.4 audio-quality acceptance scripts
    /// through the real espeak-ng phonemizer + Piper Amy and writes
    /// 16-bit PCM WAV files under `NSTemporaryDirectory()/
    /// holdclose-tts-samples/<voice>/`. The operator pulls those
    /// WAVs out of the simulator with `tools/regen_tts_samples.sh` and
    /// drops them into `docs/tts_samples/<voice>/` for the manual ear-
    /// validation pass documented in TTS_BUNDLED.md.
    ///
    /// The three scripts (source of truth — keep in sync with
    /// `docs/tts_samples/README.md` and the Android mirror in
    /// `TTSBridgeInstrumentedTest.regenerateAudioQualitySamples`):
    ///
    ///   1. `decoder_worried` — the canonical "I see you're worried…"
    ///      decoder say-line. Pulled verbatim from `fakeLLMSeeds`'
    ///      `upset` entry so the recording matches what a caregiver
    ///      actually hears in the app.
    ///   2. `crisis_card_welcome` — the crisis card AppBar title that
    ///      the screen-reader path reads first.
    ///   3. `settings_reset_confirmation` — the SnackBar shown after
    ///      "Reload seed data" — short utterance, exercises the
    ///      engine on a two-word phrase.
    ///
    /// Skips when espeak-ng isn't vendored or the bundled model isn't
    /// reachable from the test bundle (same skip semantics as
    /// `testInferenceProducesNonSilentAudio` /
    /// `testEspeakPhonemizerProducesIpaBackedIdsForHelloWorld`).
    func testRegenerateAudioQualitySamples() throws {
        #if HOLDCLOSE_HAS_ESPEAK_NG
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

        // Engine construction calls espeak_Initialize against the
        // bundled data dir; without it the espeak phonemizer would
        // silently fall back to character lookup.
        let engine = TTSEngine()
        let phonemizer = EspeakNGPhonemizer(useEspeak: true)

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holdclose-tts-samples")
            .appendingPathComponent(voiceId)
        try FileManager.default.createDirectory(at: outDir,
                                                withIntermediateDirectories: true)

        let scripts: [(slug: String, text: String)] = [
            ("decoder_worried",
             "I can see this is really hard. I'm right here with you."),
            ("crisis_card_welcome",
             "Hospital handoff card."),
            ("settings_reset_confirmation",
             "Seed reloaded."),
        ]

        for (slug, text) in scripts {
            let phonemeIds = phonemizer.phonemeIds(for: text, config: config)
            XCTAssertGreaterThan(phonemeIds.count, 2,
                                 "espeak phonemizer returned only BOS/EOS for '\(slug)' — IPA didn't land in the phoneme map")
            let samples = try engine.synthesize(phonemeIds: phonemeIds,
                                                speed: 1.0,
                                                session: session,
                                                config: config)
            XCTAssertGreaterThan(samples.count, 0,
                                 "Piper returned empty PCM for '\(slug)'")
            let url = outDir.appendingPathComponent("\(slug).wav")
            try writeWavFile(samples: samples,
                             sampleRate: 22050,
                             to: url)
            // Surface the path so the operator script can grep it out
            // of the xcodebuild log when discovering where the sim
            // dropped the files.
            print("PHASE_10_4_REGEN \(slug) \(url.path)")
        }
        #else
        throw XCTSkip("Vendored espeak-ng not present — run tools/vendor_espeak_ng.sh and `pod install`, then re-run this test")
        #endif
    }

    /// Encodes float32 PCM as a 16-bit mono PCM WAV. Format matches the
    /// universally-accepted WAVE/PCM container so a caregiver / pitch
    /// reviewer can play the file in QuickTime, VLC, or a browser
    /// without a transcode step.
    private func writeWavFile(samples: [Float],
                              sampleRate: UInt32,
                              to url: URL) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bytesPerSample)
        let blockAlign: UInt16 = numChannels * UInt16(bytesPerSample)

        var pcm16 = [Int16]()
        pcm16.reserveCapacity(samples.count)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            pcm16.append(Int16(clamped * Float(Int16.max)))
        }
        let dataBytes = pcm16.withUnsafeBufferPointer { buf -> Data in
            return Data(buffer: buf)
        }
        let dataSize = UInt32(dataBytes.count)
        let chunkSize = UInt32(36) + dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(chunkSize).littleEndianData)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndianData)            // Subchunk1Size for PCM
        header.append(UInt16(1).littleEndianData)             // AudioFormat = 1 (PCM)
        header.append(numChannels.littleEndianData)
        header.append(sampleRate.littleEndianData)
        header.append(byteRate.littleEndianData)
        header.append(blockAlign.littleEndianData)
        header.append(bitsPerSample.littleEndianData)
        header.append("data".data(using: .ascii)!)
        header.append(dataSize.littleEndianData)

        var out = header
        out.append(dataBytes)
        try out.write(to: url)
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        var le = self.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt32>.size)
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var le = self.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt16>.size)
    }
}

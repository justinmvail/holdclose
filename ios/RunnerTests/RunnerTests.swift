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
        let ids = EspeakNGPhonemizer().phonemeIds(for: "hi", config: config)
        // BOS, h, pad, i, pad, EOS
        XCTAssertEqual(ids, [1, 10, 0, 11, 0, 2])
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
}

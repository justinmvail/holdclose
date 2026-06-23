import AVFoundation
import Flutter
import Foundation
import onnxruntime_objc

// BUILD_SPEC.md Phase 9.3 — `holdclose/tts` MethodChannel handler.
//
// Replaces the AppDelegate stub: loads the bundled Piper voice
// (`en_US-amy-medium.onnx`), runs inference through ONNX Runtime
// with the CoreML execution provider enabled (Neural Engine on
// A14+), and streams the resulting PCM to an AVAudioEngine
// player node.
//
// The Dart contract (see `lib/providers/bundled_tts_provider.dart`):
//   - speak({text, voiceId, speed})    → Future<void>
//   - cancel()                         → Future<void>
//   - availableVoices()                → List<{id, displayName, locale, gender}>
enum TTSBridge {

    static let channelName = "holdclose/tts"

    private static let engine = TTSEngine()

    /// Registers the MethodChannel against a plugin registry. Called
    /// from AppDelegate once the implicit Flutter engine boots.
    static func register(with registry: FlutterPluginRegistry) {
        guard let registrar = registry.registrar(forPlugin: "CareblazersBundledTTS") else {
            return
        }
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "speak":
                guard let args = call.arguments as? [String: Any],
                      let text = args["text"] as? String else {
                    result(FlutterError(code: "BAD_ARGS",
                                        message: "speak expects {text, voiceId, speed}",
                                        details: nil))
                    return
                }
                let voiceId = args["voiceId"] as? String ?? "en_US-amy-medium"
                let speed = (args["speed"] as? NSNumber)?.doubleValue ?? 1.0
                engine.speak(text: text, voiceId: voiceId, speed: speed) { error in
                    if let error = error {
                        result(FlutterError(code: "SPEAK_FAILED",
                                            message: String(describing: error),
                                            details: nil))
                    } else {
                        result(nil)
                    }
                }
            case "cancel":
                engine.cancel()
                result(nil)
            case "availableVoices":
                result(engine.availableVoices())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

// MARK: - Engine

/// Owns the ORTSession, the phonemizer, and the AVAudioEngine. One
/// instance per process; all state mutation is funnelled through the
/// serial `workQueue` so `speak` from rapid taps can't tear inference
/// state mid-flight.
final class TTSEngine {

    /// Active voice catalog. Phase 9.5 widens this from the single
    /// bundled Amy entry; v1 ships one row.
    private static let bundledVoices: [[String: Any]] = [
        [
            "id": "en_US-amy-medium",
            "displayName": "Amy (bundled)",
            "locale": "en-US",
            "gender": "female",
        ]
    ]

    private let workQueue = DispatchQueue(label: "careblazers.tts.work", qos: .userInitiated)
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var ortEnv: ORTEnv?
    private var session: ORTSession?
    private var voiceConfig: VoiceConfig?
    private var phonemizer: Phonemizer?
    private var loadedVoiceId: String?

    /// True once `espeak_Initialize` has returned a positive sample
    /// rate for this engine instance. Read by `ensureLoaded` to decide
    /// whether the `EspeakNGPhonemizer` should call the C library or
    /// fall back to character-by-character lookup.
    #if CAREBLAZERS_HAS_ESPEAK_NG
    private var espeakReady: Bool = false
    #else
    private let espeakReady: Bool = false
    #endif

    /// Bumped on every `cancel()` so an in-flight `speak` knows to
    /// drop its pending buffer.
    private var generation: UInt64 = 0

    init() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode,
                            to: audioEngine.mainMixerNode,
                            format: TTSEngine.outputFormat)
        #if CAREBLAZERS_HAS_ESPEAK_NG
        espeakReady = TTSEngine.initializeEspeakNG()
        #endif
    }

    deinit {
        #if CAREBLAZERS_HAS_ESPEAK_NG
        if espeakReady {
            espeak_Terminate()
        }
        #endif
    }

    #if CAREBLAZERS_HAS_ESPEAK_NG
    /// Resolve the bundled espeak-ng data path and call
    /// `espeak_Initialize` once. AUDIO_OUTPUT_SYNCHRONOUS keeps the
    /// library from spinning up its own playback thread — we only use
    /// the text-to-phonemes API and AVAudioEngine handles the audio.
    /// Returns true when init succeeded and the en-US voice is
    /// selectable. The path passed to `espeak_Initialize` is the
    /// *parent* of `espeak-ng-data/` per the upstream contract.
    private static func initializeEspeakNG() -> Bool {
        guard let parentPath = locateEspeakDataParent() else {
            return false
        }
        let rate = parentPath.withCString { cstr -> Int32 in
            espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, cstr, 0)
        }
        guard rate > 0 else { return false }
        return espeak_SetVoiceByName("en-us") == EE_OK
    }

    /// CocoaPods drops the resource bundle at
    /// `Runner.app/espeak-ng.bundle/`, with `espeak-ng-data/` inside.
    /// `espeak_Initialize` wants the directory that *contains*
    /// `espeak-ng-data` — so we return the `.bundle` path itself.
    /// Fallback: the Flutter-asset mirror (`assets/tts/espeak-ng-data/`)
    /// that Android 10.3 will consume, in case the Pod resource bundle
    /// doesn't resolve in some packaging mode.
    private static func locateEspeakDataParent() -> String? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "espeak-ng", withExtension: "bundle") {
            return url.path
        }
        if let assetPath = bundle.path(
            forResource: "espeak-ng-data",
            ofType: nil,
            inDirectory: "Frameworks/App.framework/flutter_assets/assets/tts") {
            return (assetPath as NSString).deletingLastPathComponent
        }
        return nil
    }
    #endif

    /// Piper Amy ships 22050 Hz mono. AVAudioEngine accepts
    /// float32 PCM natively — that's the model's output dtype too,
    /// so the int16 round-trip the spec hints at would be wasted
    /// work. The XCTest still validates the 16-bit-equivalent
    /// envelope via int16 RMS.
    static let sampleRate: Double = 22050
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false)!

    func availableVoices() -> [[String: Any]] {
        return TTSEngine.bundledVoices
    }

    func cancel() {
        workQueue.async {
            self.generation &+= 1
            self.playerNode.stop()
            self.audioEngine.stop()
        }
    }

    func speak(text: String,
               voiceId: String,
               speed: Double,
               completion: @escaping (Error?) -> Void) {
        workQueue.async {
            self.generation &+= 1
            let myGeneration = self.generation
            do {
                try self.ensureLoaded(voiceId: voiceId)
                guard let phonemizer = self.phonemizer,
                      let session = self.session,
                      let cfg = self.voiceConfig else {
                    throw TTSError.notLoaded
                }
                let phonemeIds = phonemizer.phonemeIds(for: text, config: cfg)
                let pcm = try self.synthesize(phonemeIds: phonemeIds,
                                              speed: speed,
                                              session: session,
                                              config: cfg)
                guard myGeneration == self.generation else {
                    // A cancel landed between phonemizing and rendering;
                    // skip playback and resolve quietly.
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                try self.play(samples: pcm, completion: { err in
                    DispatchQueue.main.async { completion(err) }
                })
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    // MARK: Loading

    private func ensureLoaded(voiceId: String) throws {
        if loadedVoiceId == voiceId, session != nil { return }

        // Flutter assets land under Runner.app/Frameworks/App.framework/
        // flutter_assets/<asset-path>. Bundle.main.path(forResource:
        // ofType: inDirectory:) doesn't reach into nested frameworks,
        // so we resolve via FlutterDartProject.lookupKey first — that
        // returns the under-bundle path Flutter actually wrote.
        let modelAssetKey = FlutterDartProject.lookupKey(
            forAsset: "assets/tts/\(voiceId)/\(voiceId).onnx")
        let configAssetKey = FlutterDartProject.lookupKey(
            forAsset: "assets/tts/\(voiceId)/\(voiceId).onnx.json")
        guard let modelPath = Bundle.main.path(forResource: modelAssetKey,
                                                ofType: nil) else {
            throw TTSError.modelMissing(voiceId: voiceId)
        }
        guard let configPath = Bundle.main.path(forResource: configAssetKey,
                                                 ofType: nil) else {
            throw TTSError.configMissing(voiceId: voiceId)
        }

        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        // CoreML execution provider — routes inference to the Neural
        // Engine on A14+. Simulator + older devices fall back to CPU,
        // which adds ~1–3 s of latency per utterance (documented in
        // TTS_BUNDLED.md). MLProgram + ANE-only flags follow the
        // onnxruntime 1.18 ObjC API.
        //
        // Simulator carve-out: CoreML on the iOS Simulator uses
        // Apple's BNNS CPU path (no Neural Engine), and that path has
        // a known SIGFPE bug in certain Piper convolution kernels —
        // observable in the 2026-05-29 careblazers demo run, where the
        // app crashes mid-inference deep inside Espresso's
        // convolution_kernel::__launch. The crash happens reliably on
        // the simulator and never on real hardware. Skip the CoreML
        // EP on simulator builds; ORTSession transparently runs the
        // graph on the default CPU EP instead.
        #if !targetEnvironment(simulator)
        let coreml = ORTCoreMLExecutionProviderOptions()
        coreml.useCPUOnly = false
        coreml.enableOnSubgraphs = true
        coreml.onlyEnableForDevicesWithANE = false
        try? options.appendCoreMLExecutionProvider(with: coreml)
        #endif

        let session = try ORTSession(env: env,
                                     modelPath: modelPath,
                                     sessionOptions: options)
        let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try VoiceConfig.parse(from: configData)

        self.ortEnv = env
        self.session = session
        self.voiceConfig = config
        // On-device espeak-ng via the vendored Pod (Phase 10.2). When
        // `espeakReady` is true the phonemizer calls
        // `espeak_TextToPhonemes` for real IPA; otherwise it falls
        // back to the character-lookup path documented on the class.
        self.phonemizer = EspeakNGPhonemizer(useEspeak: espeakReady)
        self.loadedVoiceId = voiceId
    }

    // MARK: Inference

    /// Runs the Piper graph: phoneme IDs in, float32 PCM out.
    /// Exposed `internal` so the XCTest can drive it directly with a
    /// fixed phoneme array (skipping espeak-ng so the test stays
    /// hermetic).
    func synthesize(phonemeIds: [Int64],
                    speed: Double,
                    session: ORTSession,
                    config: VoiceConfig) throws -> [Float] {
        guard !phonemeIds.isEmpty else { return [] }

        var ids = phonemeIds
        let idsLength = Int64(ids.count)

        // input: int64[1, L]
        let idsData = NSMutableData(bytes: &ids, length: ids.count * MemoryLayout<Int64>.size)
        let inputShape: [NSNumber] = [1, NSNumber(value: ids.count)]
        let inputValue = try ORTValue(tensorData: idsData,
                                      elementType: .int64,
                                      shape: inputShape)

        // input_lengths: int64[1]
        var lengths: [Int64] = [idsLength]
        let lengthsData = NSMutableData(bytes: &lengths, length: MemoryLayout<Int64>.size)
        let lengthsValue = try ORTValue(tensorData: lengthsData,
                                        elementType: .int64,
                                        shape: [1])

        // scales: float32[3] = [noise_scale, length_scale, noise_w].
        // Piper convention: length_scale = 1 / speed (faster speech =
        // shorter durations). Clamp speed to a sane window to keep
        // playback from collapsing to silence on a typo.
        let safeSpeed = max(0.5, min(speed, 2.0))
        let lengthScale = Float(config.lengthScale / safeSpeed)
        var scales: [Float] = [
            Float(config.noiseScale),
            lengthScale,
            Float(config.noiseW),
        ]
        let scalesData = NSMutableData(bytes: &scales,
                                       length: scales.count * MemoryLayout<Float>.size)
        let scalesValue = try ORTValue(tensorData: scalesData,
                                       elementType: .float,
                                       shape: [3])

        let inputs: [String: ORTValue] = [
            "input": inputValue,
            "input_lengths": lengthsValue,
            "scales": scalesValue,
        ]
        let outputs = try session.run(withInputs: inputs,
                                      outputNames: ["output"],
                                      runOptions: nil)
        guard let output = outputs["output"] else {
            throw TTSError.inferenceFailed
        }
        let raw = try output.tensorData() as Data
        let count = raw.count / MemoryLayout<Float>.size
        return raw.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Float] in
            guard let base = ptr.bindMemory(to: Float.self).baseAddress else { return [] }
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }

    // MARK: Playback

    private func play(samples: [Float],
                      completion: @escaping (Error?) -> Void) throws {
        guard !samples.isEmpty else {
            completion(nil)
            return
        }

        // The shared AVAudioSession needs `.playback` so utterances
        // override the silent switch — same policy `flutter_tts` uses
        // for OSTTSProvider.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .spokenAudio, options: [])
        try audioSession.setActive(true, options: [])

        let format = TTSEngine.outputFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw TTSError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }

        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        // After the first buffer completes, AVAudioPlayerNode stays
        // in "playing" state but with no audio rendering. Calling
        // play() on a playing node is a no-op and the new
        // scheduleBuffer never engages. The canonical Apple pattern
        // for sequential playbacks is stop → scheduleBuffer → play,
        // which resets the node's internal rendering state without
        // re-attaching the audio graph. Without this, every speak()
        // after the first silently does nothing — surfaced on the
        // 2026-05-29 simulator demo as "I can only play it once."
        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: []) {
            completion(nil)
        }
        playerNode.play()
    }
}

// MARK: - Voice config

/// Subset of `<voice>.onnx.json` we need to wire inference. Anything
/// beyond `phoneme_id_map` + the inference scales is ignored — the
/// catalog metadata lives in the Dart-side voice picker.
struct VoiceConfig {
    var phonemeIdMap: [String: [Int64]]
    var noiseScale: Double
    var lengthScale: Double
    var noiseW: Double

    static func parse(from data: Data) throws -> VoiceConfig {
        guard let root = try JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any] else {
            throw TTSError.configMalformed("root is not an object")
        }
        let inference = root["inference"] as? [String: Any] ?? [:]
        let noiseScale = (inference["noise_scale"] as? NSNumber)?.doubleValue ?? 0.667
        let lengthScale = (inference["length_scale"] as? NSNumber)?.doubleValue ?? 1.0
        let noiseW = (inference["noise_w"] as? NSNumber)?.doubleValue ?? 0.8

        let rawMap = root["phoneme_id_map"] as? [String: Any] ?? [:]
        var phonemeIdMap: [String: [Int64]] = [:]
        phonemeIdMap.reserveCapacity(rawMap.count)
        for (key, value) in rawMap {
            if let arr = value as? [NSNumber] {
                phonemeIdMap[key] = arr.map { $0.int64Value }
            }
        }
        return VoiceConfig(phonemeIdMap: phonemeIdMap,
                           noiseScale: noiseScale,
                           lengthScale: lengthScale,
                           noiseW: noiseW)
    }
}

// MARK: - Phonemizer

/// Maps caregiver-facing English text to the int64 phoneme IDs the
/// Piper graph expects. Two layers:
///   1. espeak-ng IPA phonemes for the text (the real wrapper).
///   2. lookup against `phoneme_id_map` from the .onnx.json config.
protocol Phonemizer {
    func phonemeIds(for text: String, config: VoiceConfig) -> [Int64]
}

/// Wraps the espeak-ng C library. The runtime symbols are linked
/// through the vendored CocoaPod at `ios/Vendored/espeak-ng/` (see
/// `Runner-Bridging-Header.h` for the `__has_include` guard that
/// brings them into Swift visibility).
///
/// Phase 10.2 contract:
///   * `TTSEngine` calls `espeak_Initialize` once at construction and
///     hands a phonemizer with `useEspeak: true` to `ensureLoaded`.
///   * `phonemeIds(for:config:)` runs `espeak_TextToPhonemes` over the
///     input English, splits the IPA result into per-scalar tokens,
///     and maps each through `config.phonemeIdMap`. BOS (`^`), pad
///     (`_`) between phonemes, and EOS (`$`) wrap the sequence — the
///     layout Piper's tokenizer is trained against.
///
/// When the vendor script hasn't run (bridging-header `__has_include`
/// short-circuits and `CAREBLAZERS_HAS_ESPEAK_NG` Swift flag is unset),
/// or when `useEspeak` is `false` (test default), the call falls back
/// to a character-by-character lookup against `phoneme_id_map`. The
/// fallback produces non-empty IDs so the audio + integration tests
/// stay alive on a fresh checkout — but the resulting audio is
/// gibberish. Phase 10.1's README documents this contract.
final class EspeakNGPhonemizer: Phonemizer {
    private let useEspeak: Bool

    init(useEspeak: Bool = false) {
        self.useEspeak = useEspeak
    }

    func phonemeIds(for text: String, config: VoiceConfig) -> [Int64] {
        let tokens = phonemize(text)
        return EspeakNGPhonemizer.idsForTokens(tokens, config: config)
    }

    /// Resolve `text` to a phoneme-token list. Each token is a single
    /// Unicode scalar — matches the granularity of the `phoneme_id_map`
    /// keys (verified against `en_US-amy-medium.onnx.json`: all 154
    /// keys are one scalar each).
    private func phonemize(_ text: String) -> [String] {
        #if CAREBLAZERS_HAS_ESPEAK_NG
        if useEspeak, let ipa = espeakIPA(text), !ipa.isEmpty {
            return ipa
        }
        #endif
        return text.unicodeScalars.map { String($0) }
    }

    /// Wrap a token sequence with BOS (`^`), pad (`_`) between tokens,
    /// and EOS (`$`) — Piper's tokenizer expectation. Exposed
    /// `internal` so tests can supply a fixed token list and stay
    /// hermetic (no espeak link needed).
    static func idsForTokens(_ tokens: [String], config: VoiceConfig) -> [Int64] {
        var ids: [Int64] = []
        if let bos = config.phonemeIdMap["^"] { ids.append(contentsOf: bos) }
        for token in tokens {
            if let mapped = config.phonemeIdMap[token] {
                ids.append(contentsOf: mapped)
                if let pad = config.phonemeIdMap["_"] {
                    ids.append(contentsOf: pad)
                }
            }
        }
        if let eos = config.phonemeIdMap["$"] { ids.append(contentsOf: eos) }
        return ids
    }

    #if CAREBLAZERS_HAS_ESPEAK_NG
    /// Call `espeak_TextToPhonemes` over the input until the cursor
    /// reaches the trailing NUL. espeak processes one sentence per
    /// call and advances the cursor — looping covers multi-sentence
    /// inputs (decoder scripts often span two or three).
    ///
    /// phonememode `0x02` selects IPA (Unicode) output with no
    /// separator character; we tokenize the result by Unicode scalar
    /// downstream. Returns nil only on the rare path where espeak
    /// returns NULL on the first call (initialization race or an
    /// invalid UTF-8 pointer) — callers fall through to the character
    /// path in that case.
    private func espeakIPA(_ text: String) -> [String]? {
        var bytes = Array(text.utf8)
        bytes.append(0)
        return bytes.withUnsafeMutableBufferPointer { buf -> [String]? in
            guard let base = buf.baseAddress else { return nil }
            var cursor: UnsafeRawPointer? = UnsafeRawPointer(base)
            var phonemes: [String] = []
            while let raw = cursor, raw.load(as: UInt8.self) != 0 {
                guard let result = espeak_TextToPhonemes(
                    &cursor, espeakCHARS_UTF8, 0x02) else {
                    break
                }
                let ipa = String(cString: result)
                phonemes.append(contentsOf: ipa.unicodeScalars.map { String($0) })
            }
            return phonemes
        }
    }
    #endif
}

// MARK: - Errors

enum TTSError: Error, CustomStringConvertible {
    case modelMissing(voiceId: String)
    case configMissing(voiceId: String)
    case configMalformed(String)
    case notLoaded
    case inferenceFailed
    case bufferAllocationFailed

    var description: String {
        switch self {
        case .modelMissing(let id):
            return "Voice model not bundled: \(id).onnx"
        case .configMissing(let id):
            return "Voice config not bundled: \(id).onnx.json"
        case .configMalformed(let reason):
            return "Voice config malformed: \(reason)"
        case .notLoaded:
            return "TTS engine not loaded"
        case .inferenceFailed:
            return "ONNX inference produced no output tensor"
        case .bufferAllocationFailed:
            return "Could not allocate AVAudioPCMBuffer"
        }
    }
}

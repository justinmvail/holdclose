import AVFoundation
import Flutter
import Foundation
import onnxruntime_objc

// BUILD_SPEC.md Phase 9.3 — `holdclose/tts` MethodChannel handler.
//
// Replaces the AppDelegate stub: loads the bundled Piper voice
// (`en_US-hfc_female-medium.onnx`), runs inference through ONNX Runtime
// on the CPU EP (the CoreML provider segfaulted on device — see
// `ensureLoaded`), synthesizes one sentence at a time, and streams each
// sentence's PCM onto an AVAudioPlayerNode so playback starts after the
// first sentence instead of the whole reply.
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
        guard let registrar = registry.registrar(forPlugin: "HoldcloseBundledTTS") else {
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
                let voiceId = args["voiceId"] as? String ?? "en_US-hfc_female-medium"
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

    /// Active voice catalog. One bundled row: the Piper voice chosen by
    /// listening test on 2026-07-14 (hfc_female beat amy, kristin, and both
    /// "high" models, which cost ~4x the inference for no audible gain).
    private static let bundledVoices: [[String: Any]] = [
        [
            "id": "en_US-hfc_female-medium",
            "displayName": "Bundled voice",
            "locale": "en-US",
            "gender": "female",
        ]
    ]

    private let workQueue = DispatchQueue(label: "holdclose.tts.work", qos: .userInitiated)
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
    #if HOLDCLOSE_HAS_ESPEAK_NG
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
        #if HOLDCLOSE_HAS_ESPEAK_NG
        espeakReady = TTSEngine.initializeEspeakNG()
        #endif
    }

    deinit {
        #if HOLDCLOSE_HAS_ESPEAK_NG
        if espeakReady {
            espeak_Terminate()
        }
        #endif
    }

    #if HOLDCLOSE_HAS_ESPEAK_NG
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

    /// The directory that CONTAINS `espeak-ng-data/` — what `espeak_Initialize`
    /// takes. The Pod copies that folder into `Runner.app` (see the podspec's
    /// `s.resources`), so `Bundle.main.bundlePath` is normally the answer.
    ///
    /// Every candidate is VERIFIED before it's returned: a directory only counts
    /// if `espeak-ng-data/phontab` actually exists inside it. The previous
    /// version returned the first path that merely EXISTED — and the path it
    /// found (`Runner.app/espeak-ng.bundle`) held nothing but an `Info.plist`,
    /// because CocoaPods' `resource_bundles` had flattened the real data into a
    /// bundle nested inside the framework. espeak_Initialize duly failed, the
    /// phonemizer fell back to spelling words out letter-by-letter, and the
    /// coach's voice shipped as fluent gibberish (2026-07-14).
    ///
    /// Trusting a path because it resolves is how that happened. Check the file.
    private static func locateEspeakDataParent() -> String? {
        let candidates: [String?] = [
            // The Pod's `s.resources` copy. The pod builds as a framework, so
            // the folder lands at Frameworks/espeak_ng.framework/espeak-ng-data.
            // This is the ONLY complete copy — see below.
            Bundle.main.privateFrameworksURL?
                .appendingPathComponent("espeak_ng.framework").path,
            // Runner.app itself, for a non-framework (static) pod build.
            Bundle.main.bundlePath,
            // The Flutter-asset mirror. Deliberately LAST: Flutter's asset globs
            // do not recurse, so this copy has the top-level files but NOT the
            // `lang/` and `voices/` subtrees. espeak would initialise off it and
            // then fail to load the en-US voice — gibberish with extra steps.
            // The verification below rejects it; it stays only as a safety net
            // in case the pubspec ever enumerates the subdirectories.
            Bundle.main.path(
                forResource: "flutter_assets/assets/tts",
                ofType: nil,
                inDirectory: "Frameworks/App.framework"),
            // Legacy: the CocoaPods resource-BUNDLE layout (flattened).
            Bundle.main.url(forResource: "espeak-ng", withExtension: "bundle")?.path,
        ]
        for case let parent? in candidates where hasEspeakData(parent) {
            return parent
        }
        return nil
    }

    /// True when `<parent>/espeak-ng-data/` holds BOTH the phoneme table
    /// (`phontab`) and the en-US language data (`lang/gmw/en`).
    ///
    /// Checking one file is not enough, and checking the directory is worse than
    /// nothing. Two real packaging failures hid behind exactly those checks:
    /// a `Runner.app/espeak-ng.bundle` containing only an `Info.plist`, and a
    /// Flutter-asset mirror carrying `phontab` but no `lang/` subtree. Both
    /// resolve as paths. Both leave espeak unable to speak English. The bridge's
    /// fallback for "espeak isn't ready" is silent — it just spells words out
    /// letter by letter — so a wrong answer here does not raise; it babbles.
    private static func hasEspeakData(_ parent: String) -> Bool {
        let data = (parent as NSString).appendingPathComponent("espeak-ng-data")
        let fm = FileManager.default
        let phontab = (data as NSString).appendingPathComponent("phontab")
        let enVoice = (data as NSString).appendingPathComponent("lang/gmw/en")
        return fm.fileExists(atPath: phontab) && fm.fileExists(atPath: enVoice)
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

    /// Speak [text] SENTENCE BY SENTENCE, starting playback as soon as the FIRST
    /// sentence is rendered.
    ///
    /// The old shape synthesized the entire reply and only then played a single
    /// word, so the caregiver's wait grew with the length of the answer: a
    /// three-sentence reply paid for three sentences of inference before making
    /// any sound. On CPU (the only safe backend — see the CoreML note in
    /// `ensureLoaded`) that is ~1s per sentence on an A14 and noticeably worse on
    /// mid-range Android hardware.
    ///
    /// Now each sentence is rendered and queued on the player node as it becomes
    /// ready. AVAudioPlayerNode plays queued buffers gaplessly on the audio
    /// thread, so sentence 2 renders WHILE sentence 1 is speaking. Time-to-first-
    /// word stops depending on reply length, and by the time the first sentence
    /// finishes the next one is usually already waiting.
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

                let clauses = TTSEngine.splitClauses(text)
                guard !clauses.isEmpty else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                // Configure the audio session + engine ONCE per utterance, up
                // front — not per sentence. Doing it inside the per-sentence
                // enqueue meant re-activating the shared AVAudioSession on every
                // sentence, which is needless churn and an intermittent throw
                // source: a mid-utterance failure would drop to the OS fallback,
                // which then read the whole reply OVER the sentences already
                // playing (the "two voices at once" bug, 2026-07-14).
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .spokenAudio, options: [])
                try audioSession.setActive(true, options: [])
                if !self.audioEngine.isRunning {
                    try self.audioEngine.start()
                }

                // A new utterance interrupts the previous one. stop() resets the
                // node's render state; play() then starts the fresh queue.
                self.playerNode.stop()
                var started = false

                for (index, clause) in clauses.enumerated() {
                    // Bail the moment a cancel (or a newer utterance) lands —
                    // mid-render, not just before playback.
                    guard myGeneration == self.generation else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }

                    let ids = phonemizer.phonemeIds(for: clause.text, config: cfg)
                    if ids.isEmpty { continue }
                    var pcm = try self.synthesize(phonemeIds: ids,
                                                  speed: speed,
                                                  session: session,
                                                  config: cfg)

                    // A real breath after each clause — LONGER after a sentence
                    // than after a comma. The model ends a phrase abruptly, and a
                    // caregiver half-listening while doing three other things
                    // needs the beat to keep up (tuned per fb_1784072513832173:
                    // commas as long as periods used to be, periods longer).
                    let isLast = index == clauses.count - 1
                    if !isLast {
                        pcm.append(contentsOf: TTSEngine.silence(
                            seconds: clause.pause))
                    }

                    guard myGeneration == self.generation else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }

                    try self.enqueue(samples: pcm,
                                     isLast: isLast,
                                     completion: completion)

                    if !started {
                        // Sound begins HERE — after one sentence, not the whole
                        // reply.
                        self.playerNode.play()
                        started = true
                    }
                }

                if !started {
                    // Nothing was speakable (e.g. punctuation only).
                    DispatchQueue.main.async { completion(nil) }
                }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// One spoken clause + the silence to leave after it.
    struct Clause {
        let text: String
        let pause: Double
    }

    /// Split [text] into clauses at BOTH sentence-enders and commas, KEEPING the
    /// terminator on each (the phonemizer needs it to shape intonation — a
    /// question without its `?` lands flat), and tagging each with how long to
    /// pause after it: longer after a sentence than after a comma.
    ///
    /// `internal` so a unit test can pin the split without an audio engine.
    static func splitClauses(_ text: String) -> [Clause] {
        var out: [Clause] = []
        var current = ""
        func flush(_ pause: Double) {
            let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(Clause(text: s, pause: pause)) }
            current = ""
        }
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                flush(sentencePauseSeconds)
            } else if ch == "," || ch == ";" || ch == ":" {
                flush(commaPauseSeconds)
            }
        }
        flush(sentencePauseSeconds) // trailing clause; pause unused (it's last)
        return out
    }

    /// Pause after a comma / semicolon / colon — as long as a SENTENCE pause used
    /// to be (0.35s). Pause after a sentence — slightly longer. Tuned to a
    /// caregiver's ear (fb_1784072513832173). Kept in lockstep with Android's
    /// COMMA_PAUSE_SECONDS / SENTENCE_PAUSE_SECONDS.
    static let commaPauseSeconds: Double = 0.35
    static let sentencePauseSeconds: Double = 0.5

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(sampleRate * seconds))
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
        // NO CoreML execution provider. Piper runs on ORT's default CPU EP,
        // everywhere — device and simulator alike.
        //
        // The CoreML EP SEGFAULTS ON REAL HARDWARE (2026-07-14). Three
        // identical crash reports off an iPhone 12 Pro Max, every one of them:
        //
        //   EXC_BAD_ACCESS (SIGSEGV) at KERN_INVALID_ADDRESS
        //     libBNNS  BNNSFilterApplyBatch
        //     Espresso Espresso::BNNSEngine::convolution_kernel::__launch
        //     CoreML   -[MLNeuralNetworkEngine executePlan:error:]
        //
        // The code here used to carry the OPPOSITE claim — that this crash
        // "happens reliably on the simulator and never on real hardware" — and
        // skipped the EP only for simulator builds. That was never true; it was
        // just never tested, because `speak()` had no callers until the coach's
        // voice was wired up (2026-07-13). The very first real utterance on a
        // real phone killed the process, every single time.
        //
        // Note what the stack says: even on device, CoreML dispatched this graph
        // to Espresso's *BNNS* (CPU) kernels — not the Neural Engine — so the EP
        // was buying us the crash without buying the acceleration it was added
        // for. Piper's convolutions are simply not safe on that path.
        //
        // Cost of the CPU EP: ~1–3 s per utterance. Correct and slow beats fast
        // and dead. If the EP is ever reconsidered, it must be proven by running
        // integration_test/tts_bundled_smoke_test.dart ON A CABLED DEVICE — the
        // simulator cannot see this bug, because it never had the EP compiled in.
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

    /// Queue ONE sentence onto the player node. The node is already running (or
    /// about to be started by the caller), so buffers scheduled here play
    /// gaplessly, back to back, while later sentences are still rendering.
    ///
    /// The caller owns `playerNode.stop()` (once, before the first sentence) and
    /// `playerNode.play()` (once, after the first sentence is queued). Doing the
    /// old stop→schedule→play dance per BUFFER would reset the render state
    /// mid-utterance and drop everything already queued.
    private func enqueue(samples: [Float],
                         isLast: Bool,
                         completion: @escaping (Error?) -> Void) throws {
        guard !samples.isEmpty else {
            if isLast { DispatchQueue.main.async { completion(nil) } }
            return
        }

        // Audio session + engine are already configured by speak(), once per
        // utterance. This method only builds and schedules the buffer.
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

        playerNode.scheduleBuffer(buffer, at: nil, options: []) {
            // Resolve the Dart future when the LAST sentence finishes — the
            // contract callers rely on ("await speak() means the utterance is
            // done"). Resolve UNCONDITIONALLY: if a newer utterance superseded
            // this one, its stop() flushed this buffer and we still owe this
            // call's future a resolution, or `await primary.speak` hangs forever
            // (and, inside the fallback wrapper, the OS voice never gets its
            // turn).
            guard isLast else { return }
            DispatchQueue.main.async { completion(nil) }
        }
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
/// short-circuits and `HOLDCLOSE_HAS_ESPEAK_NG` Swift flag is unset),
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

    /// Punctuation Piper's tokenizer understands. These are REAL phonemes to the
    /// model — `phoneme_id_map` carries an id for each — and they are how it
    /// learns to pause at a comma, stop at a period, and lift the pitch at a
    /// question mark.
    private static let clauseTerminators: Set<Character> =
        [",", ".", "?", "!", ";", ":"]

    /// Resolve `text` to a phoneme-token list, PRESERVING clause punctuation.
    ///
    /// espeak's IPA output silently drops every punctuation mark — it uses them
    /// to shape its own internal prosody and then emits only the sounds,
    /// separating clauses with a newline:
    ///
    ///   "She took it, then rested. Did she eat?"
    ///     → "ʃiː tˈʊk ɪt\nðˈɛn ɹˈɛstᵻd\ndˈɪd ʃiː ˈiːt\n"
    ///
    /// Feeding that to Piper hands the model one undifferentiated stream with no
    /// clause boundaries and no sentence type, so it cannot pause where a person
    /// pauses and every question lands flat. Piper's own phonemizer re-attaches
    /// the terminators; ours did not, which is why the voice read everything in
    /// one breath.
    ///
    /// So: phonemize each clause on its own, then append the ORIGINAL terminator
    /// that ended it (plus a word gap), rebuilding the punctuation espeak ate.
    private func phonemize(_ text: String) -> [String] {
        #if HOLDCLOSE_HAS_ESPEAK_NG
        if useEspeak {
            var tokens: [String] = []
            for (clause, terminator) in EspeakNGPhonemizer.splitClauses(text) {
                guard let ipa = espeakIPA(clause), !ipa.isEmpty else { continue }
                tokens.append(contentsOf: ipa)
                if let terminator = terminator {
                    tokens.append(String(terminator))
                    tokens.append(" ")
                }
            }
            if !tokens.isEmpty { return tokens }
        }
        #endif
        return text.unicodeScalars.map { String($0) }
    }

    /// Break [text] into `(clause, terminator)` pairs, keeping the punctuation
    /// that ended each clause. A trailing clause with no punctuation comes back
    /// with a nil terminator.
    ///
    /// `internal` so a unit test can pin the split without linking espeak.
    static func splitClauses(_ text: String) -> [(String, Character?)] {
        var out: [(String, Character?)] = []
        var current = ""
        for ch in text {
            if clauseTerminators.contains(ch) {
                let clause = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clause.isEmpty { out.append((clause, ch)) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append((tail, nil)) }
        return out
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

    #if HOLDCLOSE_HAS_ESPEAK_NG
    /// Call `espeak_TextToPhonemes` over the input until the cursor
    /// reaches the trailing NUL. espeak processes one sentence per
    /// call and advances the cursor — looping covers multi-sentence
    /// inputs (coach scripts often span two or three).
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

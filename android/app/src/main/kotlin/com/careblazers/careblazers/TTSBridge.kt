package com.careblazers.careblazers

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtException
import ai.onnxruntime.OrtSession
import android.content.Context
import android.content.res.AssetManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.util.concurrent.Executors
import org.json.JSONObject

// BUILD_SPEC.md Phase 9.4 — `careblazers/tts` MethodChannel handler.
//
// Mirror of `ios/Runner/TTSBridge.swift`: loads the bundled Piper
// voice (`en_US-amy-medium.onnx`), runs inference through ONNX
// Runtime with the NNAPI execution provider enabled (CPU fallback on
// older devices), and streams the resulting PCM to an AudioTrack in
// streaming mode.
//
// The Dart contract (see `lib/providers/bundled_tts_provider.dart`):
//   - speak({text, voiceId, speed})    → Future<void>
//   - cancel()                         → Future<void>
//   - availableVoices()                → List<{id, displayName, locale, gender}>
object TTSBridge {

    const val CHANNEL_NAME: String = "careblazers/tts"

    /// Registers the MethodChannel against the Flutter engine. Called
    /// from `MainActivity.configureFlutterEngine`.
    fun register(context: Context, flutterEngine: FlutterEngine) {
        val engine = TTSEngine(context.applicationContext)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        val mainHandler = Handler(Looper.getMainLooper())
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.error(
                            "BAD_ARGS",
                            "speak expects {text, voiceId, speed}",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    val voiceId = call.argument<String>("voiceId")
                        ?: "en_US-amy-medium"
                    val speed = call.argument<Number>("speed")?.toDouble()
                        ?: 1.0
                    engine.speak(text, voiceId, speed) { error ->
                        mainHandler.post {
                            if (error == null) {
                                result.success(null)
                            } else {
                                result.error(
                                    "SPEAK_FAILED",
                                    error.toString(),
                                    null,
                                )
                            }
                        }
                    }
                }
                "cancel" -> {
                    engine.cancel()
                    result.success(null)
                }
                "availableVoices" -> result.success(engine.availableVoices())
                else -> result.notImplemented()
            }
        }
    }
}

// MARK: - Engine

/// Owns the `OrtSession`, the phonemizer, and the `AudioTrack`. One
/// instance per process; all state mutation is funnelled through the
/// single-thread `workExecutor` so `speak` from rapid taps can't tear
/// inference state mid-flight.
class TTSEngine(private val appContext: Context) {

    /// Active voice catalog. Phase 9.5 widens this from the single
    /// bundled Amy entry; v1 ships one row.
    private val bundledVoices: List<Map<String, Any>> = listOf(
        mapOf(
            "id" to "en_US-amy-medium",
            "displayName" to "Amy (bundled)",
            "locale" to "en-US",
            "gender" to "female",
        ),
    )

    private val workExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "careblazers.tts.work").apply { isDaemon = true }
    }

    private var ortEnv: OrtEnvironment? = null
    private var session: OrtSession? = null
    private var voiceConfig: VoiceConfig? = null
    private var phonemizer: Phonemizer? = null
    private var loadedVoiceId: String? = null

    private var audioTrack: AudioTrack? = null

    /// True once `espeak_Initialize` has returned a positive sample
    /// rate for this process. Mirror of `TTSEngine.espeakReady` on iOS.
    /// `ensureLoaded` reads this to decide whether `EspeakNGPhonemizer`
    /// should call into the JNI layer (real IPA) or fall back to the
    /// Phase 9.4 character lookup (gibberish-but-alive). Set once at
    /// construction; the JNI library is a process-level singleton, so
    /// repeated TTSEngine instances all share the same espeak state.
    private val espeakReady: Boolean = initializeEspeakNG()

    /// Bumped on every `cancel()` so an in-flight `speak` knows to
    /// drop its pending buffer.
    @Volatile
    private var generation: Long = 0L

    fun availableVoices(): List<Map<String, Any>> = bundledVoices

    /// `cancel()` runs on the calling thread (the MethodChannel
    /// handler) so it can preempt an in-flight `play()` blocking
    /// `AudioTrack.write`. Bumps the generation counter and tears
    /// down the active track; the play loop checks the counter
    /// between chunked writes and bails. Mirrors the iOS bridge's
    /// `playerNode.stop()` semantics where cancel actually
    /// interrupts ongoing audio rather than queueing behind it.
    fun cancel() {
        generation += 1
        val track = audioTrack
        audioTrack = null
        track?.let {
            try {
                if (it.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    it.pause()
                }
                it.flush()
                it.stop()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "cancel: AudioTrack already torn down", e)
            }
            it.release()
        }
    }

    fun speak(
        text: String,
        voiceId: String,
        speed: Double,
        completion: (Throwable?) -> Unit,
    ) {
        workExecutor.execute {
            generation += 1
            val myGeneration = generation
            try {
                ensureLoaded(voiceId)
                val cfg = voiceConfig
                val ph = phonemizer
                val sess = session
                if (cfg == null || ph == null || sess == null) {
                    throw TTSException.NotLoaded
                }
                val phonemeIds = ph.phonemeIds(text, cfg)
                val pcm = synthesize(phonemeIds, speed, sess, cfg)
                if (myGeneration != generation) {
                    // A cancel landed between phonemizing and rendering;
                    // skip playback and resolve quietly.
                    completion(null)
                    return@execute
                }
                play(myGeneration, pcm)
                completion(null)
            } catch (t: Throwable) {
                completion(t)
            }
        }
    }

    // MARK: Loading

    private fun ensureLoaded(voiceId: String) {
        if (loadedVoiceId == voiceId && session != null) return

        val assets = appContext.assets
        val modelBytes = readBundledAsset(assets, voiceId, "onnx")
            ?: throw TTSException.ModelMissing(voiceId)
        val configBytes = readBundledAsset(assets, "$voiceId.onnx", "json")
            ?: throw TTSException.ConfigMissing(voiceId)

        val env = OrtEnvironment.getEnvironment()
        val options = OrtSession.SessionOptions()
        options.setIntraOpNumThreads(1)
        // NNAPI execution provider — routes inference to the device
        // NPU/DSP on Android 8.1+ (API 27+). Older devices and
        // emulators fall back to CPU transparently. Mirrors the
        // CoreML EP path on iOS. Any failure here is non-fatal —
        // OrtSession transparently runs on CPU.
        try {
            options.addNnapi()
        } catch (e: OrtException) {
            Log.w(TAG, "NNAPI EP unavailable — falling back to CPU", e)
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "NNAPI native binding missing — falling back to CPU", e)
        }

        val newSession = env.createSession(modelBytes, options)
        val config = VoiceConfig.parse(configBytes)

        ortEnv = env
        session = newSession
        voiceConfig = config
        // Phase 10.3: on-device espeak-ng via the JNI bridge. When
        // `espeakReady` is true the phonemizer calls
        // `EspeakNGNative.nativeTextToPhonemes` for real IPA; otherwise
        // it falls back to the Phase 9.4 character lookup. Mirror of
        // the iOS branch — Pod-vendored static library there, JNI-
        // compiled shared library here, but the contract is identical:
        // both produce phoneme-for-phoneme aligned IDs for the bundled
        // Piper Amy voice.
        phonemizer = EspeakNGPhonemizer(useEspeak = espeakReady)
        loadedVoiceId = voiceId
    }

    // MARK: espeak-ng init

    /// One-time bootstrap. Skips when the JNI library couldn't load
    /// (fresh checkout, vendor script not yet run) or when the data
    /// directory can't be extracted from assets. Returns true only
    /// when `espeak_Initialize` reported a positive sample rate AND
    /// the en-us voice loaded — matches iOS `initializeEspeakNG`
    /// semantics so a bridge that says "ready" really is.
    private fun initializeEspeakNG(): Boolean {
        if (!EspeakNGNative.isAvailable) return false
        val dataParent = extractEspeakNGData() ?: return false
        return try {
            EspeakNGNative.nativeInitialize(dataParent) > 0
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "initializeEspeakNG: native call missing — JNI partial link?", e)
            false
        }
    }

    /// Copy `flutter_assets/assets/tts/espeak-ng-data/` from the APK
    /// into `cacheDir/espeak-ng-data/` and return the *parent* path
    /// (cacheDir). `espeak_Initialize` wants the directory that
    /// contains `espeak-ng-data/`, per the upstream contract.
    ///
    /// AssetManager hands out InputStreams, not file paths — espeak-ng
    /// is a plain C library that wants `fopen()`, so a one-time
    /// extraction is unavoidable. Cached across launches: if the
    /// target dir already has files, skip the copy.
    private fun extractEspeakNGData(): String? {
        val cacheParent = appContext.cacheDir
        val target = File(cacheParent, "espeak-ng-data")
        if (target.isDirectory && (target.list()?.size ?: 0) > 0) {
            return cacheParent.absolutePath
        }
        val assets = appContext.assets
        val assetRoot = locateEspeakAssetRoot(assets) ?: return null
        return try {
            copyAssetTree(assets, assetRoot, target)
            cacheParent.absolutePath
        } catch (e: IOException) {
            Log.w(TAG, "extractEspeakNGData: failed to copy espeak-ng-data", e)
            // Half-extracted state would make espeak crash mid-init;
            // wipe so the next attempt re-extracts from scratch.
            target.deleteRecursively()
            null
        }
    }

    private fun locateEspeakAssetRoot(assets: AssetManager): String? {
        // Mirror of readBundledAsset's candidate order — Flutter
        // bundles project assets under `flutter_assets/` but
        // hand-staged test fixtures may sit alongside.
        val candidates = listOf(
            "flutter_assets/assets/tts/espeak-ng-data",
            "assets/tts/espeak-ng-data",
        )
        for (root in candidates) {
            try {
                val entries = assets.list(root)
                if (!entries.isNullOrEmpty()) return root
            } catch (_: IOException) {
                // try next
            }
        }
        return null
    }

    /// Recursive copy. AssetManager.list returns an empty array on a
    /// file (not on a missing entry — which throws); use that to
    /// distinguish leaves from branches.
    private fun copyAssetTree(am: AssetManager, srcPath: String, dst: File) {
        val entries = try {
            am.list(srcPath)
        } catch (e: IOException) {
            null
        }
        if (entries.isNullOrEmpty()) {
            // Leaf — try to open as a file.
            dst.parentFile?.mkdirs()
            am.open(srcPath).use { input ->
                FileOutputStream(dst).use { output ->
                    input.copyTo(output)
                }
            }
            return
        }
        dst.mkdirs()
        for (entry in entries) {
            copyAssetTree(am, "$srcPath/$entry", File(dst, entry))
        }
    }

    private fun readBundledAsset(
        assets: AssetManager,
        name: String,
        ext: String,
    ): ByteArray? {
        // Flutter bundles project assets under `flutter_assets/`. Voice
        // dir is `assets/tts/en_US-amy-medium/`; try the nested path
        // first, then a flat fallback for hand-staged test fixtures.
        val candidates = listOf(
            "flutter_assets/assets/tts/en_US-amy-medium/$name.$ext",
            "assets/tts/en_US-amy-medium/$name.$ext",
            "$name.$ext",
        )
        for (path in candidates) {
            try {
                assets.open(path).use { stream ->
                    return stream.readBytes()
                }
            } catch (_: IOException) {
                // try next candidate
            }
        }
        return null
    }

    // MARK: Inference

    /// Runs the Piper graph: phoneme IDs in, float32 PCM out. Exposed
    /// `internal` so the instrumented test can drive it directly with
    /// a fixed phoneme array (skipping the phonemizer so the test
    /// stays hermetic).
    internal fun synthesize(
        phonemeIds: LongArray,
        speed: Double,
        session: OrtSession,
        config: VoiceConfig,
    ): FloatArray {
        if (phonemeIds.isEmpty()) return FloatArray(0)
        val env = ortEnv ?: OrtEnvironment.getEnvironment()

        // input: int64[1, L]
        val idsBuffer = LongBuffer.wrap(phonemeIds)
        val inputTensor = OnnxTensor.createTensor(
            env,
            idsBuffer,
            longArrayOf(1L, phonemeIds.size.toLong()),
        )

        // input_lengths: int64[1]
        val lengthsBuffer = LongBuffer.wrap(longArrayOf(phonemeIds.size.toLong()))
        val lengthsTensor = OnnxTensor.createTensor(
            env,
            lengthsBuffer,
            longArrayOf(1L),
        )

        // scales: float32[3] = [noise_scale, length_scale, noise_w].
        // Piper convention: length_scale = 1 / speed (faster speech =
        // shorter durations). Clamp speed to a sane window to keep
        // playback from collapsing to silence on a typo.
        val safeSpeed = speed.coerceIn(0.5, 2.0)
        val lengthScale = (config.lengthScale / safeSpeed).toFloat()
        val scales = floatArrayOf(
            config.noiseScale.toFloat(),
            lengthScale,
            config.noiseW.toFloat(),
        )
        val scalesTensor = OnnxTensor.createTensor(
            env,
            FloatBuffer.wrap(scales),
            longArrayOf(3L),
        )

        return try {
            val inputs = mapOf(
                "input" to inputTensor,
                "input_lengths" to lengthsTensor,
                "scales" to scalesTensor,
            )
            session.run(inputs, setOf("output")).use { results ->
                val output = results.get(0)
                flattenFloatTensor(output.value) ?: throw TTSException.InferenceFailed
            }
        } finally {
            inputTensor.close()
            lengthsTensor.close()
            scalesTensor.close()
        }
    }

    /// Piper emits float32[1, 1, T] — recursive descent flattens
    /// whatever rank the runtime returns into a single FloatArray.
    private fun flattenFloatTensor(value: Any?): FloatArray? {
        return when (value) {
            null -> null
            is FloatArray -> value
            is Array<*> -> {
                val parts = value.mapNotNull { flattenFloatTensor(it) }
                if (parts.isEmpty()) return FloatArray(0)
                val total = parts.sumOf { it.size }
                val out = FloatArray(total)
                var offset = 0
                for (part in parts) {
                    System.arraycopy(part, 0, out, offset, part.size)
                    offset += part.size
                }
                out
            }
            else -> null
        }
    }

    // MARK: Playback

    /// Float32 PCM → int16 PCM → AudioTrack streaming write at
    /// 22 050 Hz mono 16-bit, matching the Piper Amy output rate.
    /// Chunked writes let `cancel()` preempt mid-utterance by tearing
    /// down the active track between chunks.
    private fun play(myGeneration: Long, samples: FloatArray) {
        if (samples.isEmpty()) return

        val sampleRate = SAMPLE_RATE_HZ
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        ).coerceAtLeast(CHUNK_FRAMES * Short.SIZE_BYTES)

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(minBuffer)
            .build()

        audioTrack?.let { existing ->
            try {
                existing.stop()
                existing.release()
            } catch (_: IllegalStateException) {
                // already torn down
            }
        }
        audioTrack = track

        val pcm16 = ShortArray(samples.size)
        for (i in samples.indices) {
            val clamped = samples[i].coerceIn(-1.0f, 1.0f)
            pcm16[i] = (clamped * Short.MAX_VALUE.toFloat()).toInt().toShort()
        }

        track.play()
        var offset = 0
        while (offset < pcm16.size) {
            if (myGeneration != generation) {
                // cancel() landed mid-playback; bail.
                break
            }
            val remaining = pcm16.size - offset
            val chunk = if (remaining < CHUNK_FRAMES) remaining else CHUNK_FRAMES
            val written = track.write(
                pcm16,
                offset,
                chunk,
                AudioTrack.WRITE_BLOCKING,
            )
            if (written <= 0) break
            offset += written
        }
        // STREAM mode keeps draining after the last write returns;
        // `stop()` schedules a graceful tail-flush. Skipped if cancel
        // already tore the track down.
        if (audioTrack === track) {
            try {
                track.stop()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "play: AudioTrack stop after underrun", e)
            }
            track.release()
            audioTrack = null
        }
    }

    companion object {
        // Piper Amy ships 22 050 Hz mono. AudioTrack consumes int16
        // PCM at this rate directly — the float32 → int16 conversion
        // is the only host-side resampling we do.
        const val SAMPLE_RATE_HZ: Int = 22050

        // ~46 ms of audio per write; small enough that `cancel()`
        // preempts mid-utterance with a barely-perceptible tail.
        private const val CHUNK_FRAMES: Int = 1024

        private const val TAG: String = "TTSBridge"
    }
}

// MARK: - Voice config

/// Subset of `<voice>.onnx.json` we need to wire inference. Anything
/// beyond `phoneme_id_map` + the inference scales is ignored — the
/// catalog metadata lives in the Dart-side voice picker.
data class VoiceConfig(
    val phonemeIdMap: Map<String, LongArray>,
    val noiseScale: Double,
    val lengthScale: Double,
    val noiseW: Double,
) {
    companion object {
        fun parse(bytes: ByteArray): VoiceConfig {
            val root = JSONObject(String(bytes, Charsets.UTF_8))
            val inference = root.optJSONObject("inference") ?: JSONObject()
            val noiseScale = inference.optDouble("noise_scale", 0.667)
            val lengthScale = inference.optDouble("length_scale", 1.0)
            val noiseW = inference.optDouble("noise_w", 0.8)

            val rawMap = root.optJSONObject("phoneme_id_map") ?: JSONObject()
            val phonemeIdMap = HashMap<String, LongArray>(rawMap.length())
            val keys = rawMap.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val arr = rawMap.optJSONArray(key) ?: continue
                val ids = LongArray(arr.length()) { i -> arr.optLong(i, 0L) }
                phonemeIdMap[key] = ids
            }
            return VoiceConfig(
                phonemeIdMap = phonemeIdMap,
                noiseScale = noiseScale,
                lengthScale = lengthScale,
                noiseW = noiseW,
            )
        }
    }
}

// MARK: - Phonemizer

/// Maps caregiver-facing English text to the int64 phoneme IDs the
/// Piper graph expects. Two layers:
///   1. espeak-ng IPA phonemes for the text (the real wrapper).
///   2. lookup against `phoneme_id_map` from the .onnx.json config.
interface Phonemizer {
    fun phonemeIds(text: String, config: VoiceConfig): LongArray
}

/// Wraps the espeak-ng C library via the `EspeakNGNative` JNI bridge.
/// The native sources are populated by `tools/vendor_espeak_ng.sh` into
/// `android/app/src/main/cpp/espeak-ng/` and compiled into
/// `libcareblazers_espeak_ng.so` by the externalNativeBuild config in
/// `app/build.gradle.kts`. See `android/app/src/main/cpp/README.md`
/// for the layout + symbol naming.
///
/// Phase 10.3 contract:
///   * `TTSEngine` calls `EspeakNGNative.nativeInitialize` once at
///     construction (with the espeak-ng-data path extracted from the
///     APK assets) and hands a phonemizer with `useEspeak: true` to
///     `ensureLoaded`.
///   * `phonemeIds(text, config)` runs `nativeTextToPhonemes` over the
///     input English, splits the IPA result into per-scalar tokens,
///     and maps each through `config.phonemeIdMap`. BOS (`^`), pad
///     (`_`) between phonemes, and EOS (`$`) wrap the sequence — the
///     layout Piper's tokenizer is trained against.
///
/// When the vendor script hasn't run (the CMake `file(GLOB)` resolves
/// to no espeak sources and the JNI shim's `__has_include` flips off),
/// or when `useEspeak` is `false` (test default), the call falls back
/// to a character-by-character lookup against `phoneme_id_map`. The
/// fallback produces non-empty IDs so the audio + integration tests
/// stay alive on a fresh checkout — but the resulting audio is
/// gibberish. The iOS bridging-header README documents the same
/// contract for the Swift twin.
class EspeakNGPhonemizer(private val useEspeak: Boolean = false) : Phonemizer {
    override fun phonemeIds(text: String, config: VoiceConfig): LongArray {
        val tokens = tokens(text)
        return idsForTokens(tokens, config)
    }

    /// Resolve `text` to a phoneme-token list. Each token is a single
    /// Unicode scalar — matches the granularity of `phoneme_id_map`
    /// keys (verified against `en_US-amy-medium.onnx.json`: all 154
    /// keys are one scalar each).
    private fun tokens(text: String): List<String> {
        if (useEspeak && EspeakNGNative.isAvailable) {
            try {
                val ipa = EspeakNGNative.nativeTextToPhonemes(text)
                if (!ipa.isNullOrEmpty()) {
                    return ipa.map { it.toString() }
                }
            } catch (e: UnsatisfiedLinkError) {
                // JNI fn went missing between init + call (shouldn't
                // happen, but System.loadLibrary can race with a
                // process restart). Fall through to character lookup.
                Log.w("TTSBridge", "nativeTextToPhonemes unavailable — falling back", e)
            }
        }
        return text.map { it.toString() }
    }

    companion object {
        /// Wrap a token sequence with BOS (`^`), pad (`_`) between
        /// tokens, and EOS (`$`) — Piper's tokenizer expectation.
        /// Exposed at companion-level so tests can supply a fixed
        /// token list and stay hermetic (no JNI link needed).
        fun idsForTokens(tokens: List<String>, config: VoiceConfig): LongArray {
            val ids = ArrayList<Long>(tokens.size * 3 + 2)
            config.phonemeIdMap["^"]?.let { appendAll(ids, it) }
            val pad = config.phonemeIdMap["_"]
            for (token in tokens) {
                val mapped = config.phonemeIdMap[token] ?: continue
                appendAll(ids, mapped)
                if (pad != null) appendAll(ids, pad)
            }
            config.phonemeIdMap["$"]?.let { appendAll(ids, it) }
            return ids.toLongArray()
        }

        private fun appendAll(dst: ArrayList<Long>, src: LongArray) {
            dst.ensureCapacity(dst.size + src.size)
            for (v in src) dst.add(v)
        }
    }
}

// MARK: - JNI bridge

/// Singleton wrapper around `libcareblazers_espeak_ng.so`. The C++
/// shim lives at `android/app/src/main/cpp/careblazers_espeak_ng.cpp`;
/// CMake compiles it on every native build. `isAvailable` is true
/// iff the .so loaded *and* the espeak-ng sources were linked into it
/// (the JNI shim's `__has_include` guard flipped on when
/// `tools/vendor_espeak_ng.sh` had run). When false, callers fall
/// back to the character-lookup phonemizer documented above.
object EspeakNGNative {

    /// Set once at class-load: true iff `System.loadLibrary` succeeded
    /// AND `nativeHasEspeakNG` reported the symbols are linked. Read
    /// by `TTSEngine.initializeEspeakNG` and `EspeakNGPhonemizer`.
    val isAvailable: Boolean

    init {
        var available = false
        try {
            System.loadLibrary("careblazers_espeak_ng")
            available = nativeHasEspeakNG()
        } catch (e: UnsatisfiedLinkError) {
            Log.w("TTSBridge", "libcareblazers_espeak_ng not loadable — bridge falls back to character phonemizer", e)
        }
        isAvailable = available
    }

    /// Compile-time flag exposed from the JNI shim. Returns true iff
    /// `__has_include(<espeak-ng/espeak_ng.h>)` was true at compile
    /// time — i.e., the vendor script had populated cpp/espeak-ng/
    /// before the last CMake run.
    external fun nativeHasEspeakNG(): Boolean

    /// Wraps `espeak_Initialize` + `espeak_SetVoiceByName("en-us")`.
    /// `dataParentPath` is the directory that *contains*
    /// `espeak-ng-data/` — TTSEngine extracts the asset tree into
    /// `cacheDir/espeak-ng-data/` and passes `cacheDir` here. Returns
    /// the sample rate on success (>0), or a negative status code
    /// (-1/-2/-3, see careblazers_espeak_ng.cpp) on failure.
    external fun nativeInitialize(dataParentPath: String): Int

    /// Wraps `espeak_TextToPhonemes` looped to consume the full input.
    /// Returns the IPA-phoneme string for `text`, or null when the
    /// espeak symbols aren't linked / the call failed mid-loop.
    external fun nativeTextToPhonemes(text: String): String?

    /// Wraps `espeak_Terminate`. Currently unused — TTSEngine has no
    /// teardown hook (the engine is a process-singleton), and espeak's
    /// state is fine to leak for the process lifetime. Exposed so a
    /// future test harness can reset between runs without restarting
    /// the process.
    external fun nativeTerminate()
}

// MARK: - Errors

sealed class TTSException(message: String) : RuntimeException(message) {
    class ModelMissing(voiceId: String) :
        TTSException("Voice model not bundled: $voiceId.onnx")

    class ConfigMissing(voiceId: String) :
        TTSException("Voice config not bundled: $voiceId.onnx.json")

    class ConfigMalformed(reason: String) :
        TTSException("Voice config malformed: $reason")

    object NotLoaded : TTSException("TTS engine not loaded")

    object InferenceFailed :
        TTSException("ONNX inference produced no output tensor")
}

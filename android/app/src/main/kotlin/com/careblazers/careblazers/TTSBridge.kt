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
        phonemizer = EspeakNGPhonemizer()
        loadedVoiceId = voiceId
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

/// Mirror of the iOS `EspeakNGPhonemizer` stub. The task spec hints
/// at `espeakng-java` (Maven Central) or a thin JNI wrapper; until
/// that vendor drop lands we perform a character-by-character lookup
/// against `phoneme_id_map` (BOS/EOS + pad tokens around each
/// grapheme) so the audio pipeline + tests stay alive. Production
/// English phonemization arrives with the same follow-up that
/// vendors espeak-ng for iOS.
class EspeakNGPhonemizer : Phonemizer {
    override fun phonemeIds(text: String, config: VoiceConfig): LongArray {
        val ids = ArrayList<Long>(text.length * 3 + 2)
        val pad = config.phonemeIdMap["_"]
        // BOS token is encoded as '^' in Piper configs.
        config.phonemeIdMap["^"]?.let { appendAll(ids, it) }
        for (ch in text) {
            val mapped = config.phonemeIdMap[ch.toString()] ?: continue
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

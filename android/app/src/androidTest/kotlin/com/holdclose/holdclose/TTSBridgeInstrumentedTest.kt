package com.holdclose.holdclose

import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

// BUILD_SPEC.md Phase 9.4 acceptance: assert the bridge can load the
// bundled voice model and that inference produces non-silent audio.
//
// Mirrors `ios/RunnerTests/RunnerTests.swift`. The hermetic tests
// (config parser, phonemizer lookup, voice catalog) always run; the
// model-load + RMS test skips when the `.onnx` asset isn't reachable
// from the instrumented APK — Phase 9.6 covers real-device runs.
@RunWith(AndroidJUnit4::class)
class TTSBridgeInstrumentedTest {

    @Test
    fun voiceConfigParsesPiperJson() {
        val json = """
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
        """.trimIndent().toByteArray(Charsets.UTF_8)

        val config = VoiceConfig.parse(json)
        assertEquals(0.667, config.noiseScale, 1e-6)
        assertEquals(1.0, config.lengthScale, 1e-6)
        assertEquals(0.8, config.noiseW, 1e-6)
        assertEquals(listOf(42L), config.phonemeIdMap["h"]?.toList())
        assertEquals(listOf(1L), config.phonemeIdMap["^"]?.toList())
    }

    @Test
    fun phonemizerEmitsBosEosAndPadPerCharacter() {
        val config = VoiceConfig(
            phonemeIdMap = mapOf(
                "^" to longArrayOf(1L),
                "$" to longArrayOf(2L),
                "_" to longArrayOf(0L),
                "h" to longArrayOf(10L),
                "i" to longArrayOf(11L),
            ),
            noiseScale = 0.667,
            lengthScale = 1.0,
            noiseW = 0.8,
        )
        // Default `useEspeak = false` exercises the character-by-character
        // fallback path documented in cpp/README.md — the only path
        // available on a fresh checkout that hasn't run the vendor
        // script. Mirror of iOS `testPhonemizerEmitsBosEosAndPadPerCharacter`.
        val ids = EspeakNGPhonemizer().phonemeIds("hi", config)
        // BOS, h, pad, i, pad, EOS
        assertEquals(listOf(1L, 10L, 0L, 11L, 0L, 2L), ids.toList())
    }

    /// Phase 10.3: the BOS/pad/EOS wrapper is shared between the espeak
    /// JNI and fallback paths. Drive it directly with a fixed token
    /// list so the wrapper invariant is covered even when the JNI
    /// library isn't linked. Mirror of iOS `testIdsForTokensWrapsWithBosPadEos`.
    @Test
    fun idsForTokensWrapsWithBosPadEos() {
        val config = VoiceConfig(
            phonemeIdMap = mapOf(
                "^" to longArrayOf(1L),
                "$" to longArrayOf(2L),
                "_" to longArrayOf(0L),
                "h" to longArrayOf(20L),
                "ə" to longArrayOf(27L),
                "l" to longArrayOf(24L),
                "o" to longArrayOf(25L),
                "ʊ" to longArrayOf(50L),
            ),
            noiseScale = 0.667,
            lengthScale = 1.0,
            noiseW = 0.8,
        )
        val ids = EspeakNGPhonemizer.idsForTokens(
            listOf("h", "ə", "l", "o", "ʊ"), config,
        )
        // BOS, h, pad, ə, pad, l, pad, o, pad, ʊ, pad, EOS
        assertEquals(
            listOf(1L, 20L, 0L, 27L, 0L, 24L, 0L, 25L, 0L, 50L, 0L, 2L),
            ids.toList(),
        )
    }

    @Test
    fun engineExposesBundledAmyVoice() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val voices = TTSEngine(context).availableVoices()
        assertEquals(1, voices.size)
        assertEquals("en_US-amy-medium", voices.first()["id"])
        assertEquals("en-US", voices.first()["locale"])
    }

    /// End-to-end: load the bundled ONNX, run a fixed phoneme array
    /// through `synthesize`, assert the PCM RMS clears zero. Skips
    /// when the `.onnx` isn't reachable from the instrumented APK
    /// (Flutter bundles assets into the host APK; AndroidJUnitRunner
    /// runs against the target APK so the asset path is shared, but
    /// CI emulators may not have the 30 MB voice staged).
    @Test
    fun inferenceProducesNonSilentAudio() {
        val voiceId = "en_US-amy-medium"
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val assets = context.assets
        val modelBytes = readAsset(assets, "$voiceId.onnx")
        val configBytes = readAsset(assets, "$voiceId.onnx.json")
        assumeTrue(
            "$voiceId.onnx not reachable from APK — covered by Phase 9.6 device smoke",
            modelBytes != null && configBytes != null,
        )

        val env = OrtEnvironment.getEnvironment()
        val opts = OrtSession.SessionOptions().apply { setIntraOpNumThreads(1) }
        val session = env.createSession(modelBytes!!, opts)
        val config = VoiceConfig.parse(configBytes!!)

        val phonemeIds = EspeakNGPhonemizer().phonemeIds("hello", config)
        assertTrue(
            "phonemizer fell through to empty IDs — config map is missing the test chars",
            phonemeIds.isNotEmpty(),
        )

        val engine = TTSEngine(context)
        val samples = engine.synthesize(phonemeIds, 1.0, session, config)
        assertTrue("model returned an empty output tensor", samples.isNotEmpty())

        var sumSq = 0.0
        for (s in samples) sumSq += (s * s).toDouble()
        val rms = sqrt(sumSq / samples.size)
        assertNotEquals(
            "inference RMS was zero — model loaded but produced silence",
            0.0,
            rms,
        )
    }

    private fun readAsset(
        assets: android.content.res.AssetManager,
        name: String,
    ): ByteArray? {
        // Mirror of TTSEngine.readBundledAsset's candidate order.
        val candidates = listOf(
            "flutter_assets/assets/tts/en_US-amy-medium/$name",
            "assets/tts/en_US-amy-medium/$name",
            name,
        )
        for (path in candidates) {
            try {
                assets.open(path).use { return it.readBytes() }
            } catch (_: java.io.IOException) {
                // try next candidate
            }
        }
        return null
    }

    // MARK: Phase 10.3 — espeak-ng JNI vendor smoke

    /// Loads the vendored espeak-ng JNI library, drives a TTSEngine
    /// (which calls `espeak_Initialize` against the extracted data
    /// dir), and asserts a non-empty IPA-phoneme string comes back
    /// from `nativeTextToPhonemes("hello world")`. Mirror of iOS
    /// `testEspeakNgVendorLoadsAndPhonemizes`.
    ///
    /// Skips when `EspeakNGNative.isAvailable` is false — that's the
    /// state before `tools/vendor_espeak_ng.sh` runs (the JNI shim's
    /// `__has_include` short-circuits and `nativeHasEspeakNG` returns
    /// false) or when libholdclose_espeak_ng.so failed to load.
    @Test
    fun espeakNgVendorLoadsAndPhonemizes() {
        assumeTrue(
            "espeak-ng JNI not linked — run tools/vendor_espeak_ng.sh and rebuild",
            EspeakNGNative.isAvailable,
        )
        val context = InstrumentationRegistry.getInstrumentation().targetContext

        // Constructing the engine runs `initializeEspeakNG` which
        // extracts the espeak-ng-data tree out of the APK assets and
        // calls `espeak_Initialize`. If this throws or returns
        // `espeakReady = false`, the espeak data dir wasn't reachable
        // (assets/tts/espeak-ng-data/ wasn't populated by the vendor
        // script before the build).
        val engine = TTSEngine(context)
        assertNotNull("TTSEngine construction failed", engine)

        val ipa = EspeakNGNative.nativeTextToPhonemes("hello world")
        assertNotNull("nativeTextToPhonemes returned null", ipa)
        assertTrue(
            "nativeTextToPhonemes returned empty IPA — espeak_Initialize never " +
                "succeeded against the extracted data dir",
            !ipa.isNullOrEmpty(),
        )
    }

    /// Phase 10.3 acceptance: with the JNI bridge wired,
    /// `EspeakNGPhonemizer(useEspeak = true).phonemeIds("hello world", cfg)`
    /// must produce a non-empty ID sequence that differs from the
    /// character-lookup fallback — proves the JNI path actually ran
    /// instead of silently falling through. The phoneme-for-phoneme
    /// exact-match check against Piper's Python reference impl is
    /// captured in `docs/tts_samples/` during Phase 10.4 manual
    /// validation; here we only assert the wiring.
    ///
    /// Skips when the JNI library isn't linked (fresh checkout) or
    /// when the voice config asset isn't reachable from the APK
    /// (same skip semantics as `inferenceProducesNonSilentAudio`).
    @Test
    fun espeakPhonemizerProducesIpaBackedIdsForHelloWorld() {
        assumeTrue(
            "espeak-ng JNI not linked — run tools/vendor_espeak_ng.sh and rebuild",
            EspeakNGNative.isAvailable,
        )
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val configBytes = readAsset(context.assets, "en_US-amy-medium.onnx.json")
        assumeTrue(
            "en_US-amy-medium.onnx.json not reachable from APK — covered by Phase 9.6 device smoke",
            configBytes != null,
        )
        val config = VoiceConfig.parse(configBytes!!)

        // Force an engine construction so `espeak_Initialize` runs
        // against the extracted data dir before the phonemizer asks
        // for IDs.
        TTSEngine(context)

        val realIds = EspeakNGPhonemizer(useEspeak = true)
            .phonemeIds("hello world", config)
        val fallbackIds = EspeakNGPhonemizer(useEspeak = false)
            .phonemeIds("hello world", config)

        assertTrue(
            "espeak path returned only BOS/EOS — IPA tokens didn't land in the phoneme map",
            realIds.size > 2,
        )
        assertEquals(
            "espeak path didn't prefix BOS",
            config.phonemeIdMap["^"]?.firstOrNull(),
            realIds.firstOrNull(),
        )
        assertEquals(
            "espeak path didn't suffix EOS",
            config.phonemeIdMap["$"]?.firstOrNull(),
            realIds.lastOrNull(),
        )
        assertNotEquals(
            "espeak path matched the character-lookup fallback — nativeTextToPhonemes never ran",
            fallbackIds.toList(),
            realIds.toList(),
        )
    }

    // MARK: Phase 10.4 — audio-quality sample regen

    /// Renders the three Phase 10.4 audio-quality acceptance scripts
    /// through the real espeak-ng JNI phonemizer + Piper Amy and writes
    /// 16-bit PCM WAV files under
    /// `Context.getExternalFilesDir(null)/tts_samples/<voice>/`. The
    /// operator pulls those WAVs off the device with
    /// `tools/regen_tts_samples.sh` (via `adb pull`) and drops them
    /// into `docs/tts_samples/<voice>/` for the manual ear-validation
    /// pass documented in TTS_BUNDLED.md.
    ///
    /// The three scripts are the same set the iOS XCTest writes (see
    /// `RunnerTests.testRegenerateAudioQualitySamples` and
    /// `docs/tts_samples/README.md`); the byte-for-byte WAV outputs
    /// won't match across platforms (CoreML EP vs. NNAPI quantisation
    /// + Apple float-conversion rounding differs from the Android JNI
    /// pipeline) but the prosody + warmth should land the same.
    ///
    /// Skips when espeak-ng JNI isn't linked (fresh checkout) or the
    /// model asset isn't reachable (same skip semantics as the other
    /// 10.x tests).
    @Test
    fun regenerateAudioQualitySamples() {
        assumeTrue(
            "espeak-ng JNI not linked — run tools/vendor_espeak_ng.sh and rebuild",
            EspeakNGNative.isAvailable,
        )
        val voiceId = "en_US-amy-medium"
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val assets = context.assets
        val modelBytes = readAsset(assets, "$voiceId.onnx")
        val configBytes = readAsset(assets, "$voiceId.onnx.json")
        assumeTrue(
            "$voiceId.onnx not reachable from APK — covered by Phase 9.6 device smoke",
            modelBytes != null && configBytes != null,
        )

        val env = OrtEnvironment.getEnvironment()
        val opts = OrtSession.SessionOptions().apply { setIntraOpNumThreads(1) }
        val session = env.createSession(modelBytes!!, opts)
        val config = VoiceConfig.parse(configBytes!!)

        // Engine construction extracts espeak-ng-data and calls
        // espeak_Initialize against it. Without that the JNI
        // phonemizer would return empty IPA.
        val engine = TTSEngine(context)
        val phonemizer = EspeakNGPhonemizer(useEspeak = true)

        val externalRoot = context.getExternalFilesDir(null)
            ?: throw AssertionError("getExternalFilesDir(null) returned null — device has no shared storage")
        val outDir = File(externalRoot, "tts_samples/$voiceId").apply {
            mkdirs()
        }

        val scripts = listOf(
            "coach_worried" to
                "I can see this is really hard. I'm right here with you.",
            "crisis_card_welcome" to
                "Hospital handoff card.",
            "settings_reset_confirmation" to
                "Seed reloaded.",
        )

        for ((slug, text) in scripts) {
            val phonemeIds = phonemizer.phonemeIds(text, config)
            assertTrue(
                "espeak JNI returned only BOS/EOS for '$slug' — IPA didn't land in the phoneme map",
                phonemeIds.size > 2,
            )
            val samples = engine.synthesize(phonemeIds, 1.0, session, config)
            assertTrue(
                "Piper returned empty PCM for '$slug'",
                samples.isNotEmpty(),
            )
            val target = File(outDir, "$slug.wav")
            writeWavFile(samples, sampleRate = 22050, file = target)
            // Surface the path so the operator script can grep it out
            // of the instrumented-test log when discovering where the
            // device dropped the files.
            println("PHASE_10_4_REGEN $slug ${target.absolutePath}")
        }
    }

    /// Encodes float32 PCM as a 16-bit mono PCM WAV. Format mirrors
    /// the iOS WAV writer so the operator can A/B-compare across
    /// platforms without a transcode step.
    private fun writeWavFile(samples: FloatArray, sampleRate: Int, file: File) {
        val numChannels: Short = 1
        val bitsPerSample: Short = 16
        val bytesPerSample = bitsPerSample / 8
        val byteRate = sampleRate * numChannels * bytesPerSample
        val blockAlign: Short = (numChannels * bytesPerSample).toShort()
        val dataSize = samples.size * bytesPerSample
        val chunkSize = 36 + dataSize

        FileOutputStream(file).use { out ->
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray(Charsets.US_ASCII))
            header.putInt(chunkSize)
            header.put("WAVE".toByteArray(Charsets.US_ASCII))
            header.put("fmt ".toByteArray(Charsets.US_ASCII))
            header.putInt(16)                 // Subchunk1Size for PCM
            header.putShort(1.toShort())      // AudioFormat = 1 (PCM)
            header.putShort(numChannels)
            header.putInt(sampleRate)
            header.putInt(byteRate)
            header.putShort(blockAlign)
            header.putShort(bitsPerSample)
            header.put("data".toByteArray(Charsets.US_ASCII))
            header.putInt(dataSize)
            out.write(header.array())

            val payload = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
            for (s in samples) {
                val clamped = s.coerceIn(-1f, 1f)
                payload.putShort((clamped * Short.MAX_VALUE).toInt().toShort())
            }
            out.write(payload.array())
        }
    }
}

package com.careblazers.careblazers

import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
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
        val ids = EspeakNGPhonemizer().phonemeIds("hi", config)
        // BOS, h, pad, i, pad, EOS
        assertEquals(listOf(1L, 10L, 0L, 11L, 0L, 2L), ids.toList())
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
}

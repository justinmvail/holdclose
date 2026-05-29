package com.careblazers.careblazers

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // BUILD_SPEC.md Phase 9.2 — `careblazers/tts` MethodChannel contract.
    // Stub handler: `speak`/`cancel` succeed with no payload and
    // `availableVoices` returns an empty list. Phase 9.4 replaces this
    // with the OrtSession + NNAPI execution provider wiring + AudioTrack
    // playback.
    private val ttsChannelName = "careblazers/tts"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ttsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speak", "cancel" -> result.success(null)
                    "availableVoices" -> result.success(emptyList<Map<String, Any>>())
                    else -> result.notImplemented()
                }
            }
    }
}

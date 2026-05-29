package com.careblazers.careblazers

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // BUILD_SPEC.md Phase 9.4 — `careblazers/tts` MethodChannel handler.
    // Hands speak/cancel/availableVoices off to TTSBridge.kt, which
    // owns the OrtSession + NNAPI execution provider + AudioTrack
    // playback. Replaces the Phase 9.2 stub.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        TTSBridge.register(applicationContext, flutterEngine)
    }
}

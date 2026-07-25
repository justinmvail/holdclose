package com.holdclose.holdclose

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // BUILD_SPEC.md Phase 9.4 — `holdclose/tts` MethodChannel handler.
    // Hands speak/cancel/availableVoices off to TTSBridge.kt, which
    // owns the OrtSession + NNAPI execution provider + AudioTrack
    // playback. Replaces the Phase 9.2 stub.
    //
    // Also wires `holdclose/document_import` (Restore from backup) —
    // DocumentImportBridge is handed this activity's engine (protected
    // getFlutterEngine, reachable from the subclass) and drives the
    // ACTION_OPEN_DOCUMENT picker via startActivityForResult; results come
    // back through onActivityResult below.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        TTSBridge.register(applicationContext, flutterEngine)
        DocumentImportBridge.register(this, flutterEngine)
    }

    // FlutterActivity extends plain Activity, so the document picker uses the
    // classic request-code round-trip. Forward the backup-pick result to the
    // bridge, which reads the file's bytes and answers the parked Dart call.
    @Deprecated("startActivityForResult round-trip — FlutterActivity is not a ComponentActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == DocumentImportBridge.REQUEST_PICK_BACKUP) {
            DocumentImportBridge.onDocumentPicked(this, resultCode, data)
        }
    }
}

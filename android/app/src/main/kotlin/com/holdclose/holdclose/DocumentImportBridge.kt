package com.holdclose.holdclose

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

// `holdclose/document_import` MethodChannel — the Android twin of
// `ios/Runner/DocumentPickerBridge.swift`. Lets "Restore from backup"
// (Settings → Your data) pull a previously-exported Holdclose JSON backup
// back in. There's no `file_picker` package in the app (no new dependency
// posture), so this wraps ACTION_OPEN_DOCUMENT directly and hands the chosen
// file's bytes to Dart.
//
// The Dart contract (`lib/services/data_exporter.dart`, RealDataFilePicker):
//   pickJson() → Future<Uint8List?>   (null when the caregiver cancelled)
//
// The iOS bridge returns FlutterStandardTypedData(bytes:), which Dart's
// `invokeMethod<Uint8List>` receives as a Uint8List. This bridge returns a
// Kotlin ByteArray for the same call, which the standard codec likewise
// decodes to a Uint8List — an identical contract on both platforms, so the
// Dart side (importFromBytes → utf8.decode) is unchanged.
//
// Activity-result plumbing: `FlutterActivity` extends plain `Activity` (not
// ComponentActivity), so there's no ActivityResultLauncher — this uses the
// classic startActivityForResult + onActivityResult request-code pattern.
// MainActivity forwards its onActivityResult here.
object DocumentImportBridge {

    const val CHANNEL_NAME: String = "holdclose/document_import"

    // Request code for the ACTION_OPEN_DOCUMENT round-trip. Private to this
    // bridge; MainActivity checks it before forwarding a result.
    const val REQUEST_PICK_BACKUP: Int = 0xB0C

    // JSON, plus a plain-text fallback for backups shared without a MIME
    // type. Mirrors the iOS UTType list ([.json, .plainText]).
    private val MIME_TYPES: Array<String> = arrayOf("application/json", "text/plain")

    // Strong-held while a pick is in flight — the picker result arrives on a
    // separate activity callback, so the Dart Result that opened the picker
    // must survive until then. One-shot: cleared the instant we answer.
    private var pendingResult: MethodChannel.Result? = null

    /// Registers the MethodChannel against the engine. Called from
    /// `MainActivity.configureFlutterEngine` (which has protected access to
    /// the engine and passes it in).
    fun register(activity: MainActivity, flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickJson" -> presentPicker(activity, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun presentPicker(activity: Activity, result: MethodChannel.Result) {
        // A pick already in flight — resolve the newcomer as a no-op rather
        // than clobbering the outstanding Result.
        if (pendingResult != null) {
            result.success(null)
            return
        }
        pendingResult = result

        // ACTION_OPEN_DOCUMENT vends a persistable, readable Uri (vs.
        // GET_CONTENT which can hand back a cache copy) — the analogue of
        // the iOS document picker's security-scoped Url.
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, MIME_TYPES)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_PICK_BACKUP)
        } catch (e: android.content.ActivityNotFoundException) {
            // No activity to handle ACTION_OPEN_DOCUMENT (heavily stripped
            // OEM build) — answer null, same as a cancel.
            Log.w(TAG, "presentPicker: no document picker available", e)
            finish(null)
        }
    }

    /// Called by MainActivity.onActivityResult for REQUEST_PICK_BACKUP.
    /// `data` is null (and resultCode != OK) when the caregiver cancelled.
    /// Reads the file's bytes off the resolver and answers the parked Dart
    /// Result exactly once.
    fun onDocumentPicked(activity: Activity, resultCode: Int, data: Intent?) {
        val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            finish(null)
            return
        }
        val bytes = try {
            activity.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: IOException) {
            Log.w(TAG, "onDocumentPicked: failed to read picked file", e)
            null
        } catch (e: SecurityException) {
            Log.w(TAG, "onDocumentPicked: no read grant for picked file", e)
            null
        }
        finish(bytes)
    }

    /// Answer the pending Result once, then release it. `bytes` maps to a
    /// Dart Uint8List; null maps to a Dart null ("nothing picked").
    private fun finish(bytes: ByteArray?) {
        val result = pendingResult ?: return
        pendingResult = null
        result.success(bytes)
    }

    private const val TAG: String = "DocumentImportBridge"
}

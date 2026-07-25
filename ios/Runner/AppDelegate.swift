import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // BUILD_SPEC.md Phase 9.3 — `holdclose/tts` MethodChannel handler.
    // Hands speak/cancel/availableVoices off to TTSBridge.swift, which
    // owns the ORTSession + AVAudioEngine.
    TTSBridge.register(with: engineBridge.pluginRegistry)
    // `holdclose/backup_exclusion` MethodChannel — flips
    // NSURLIsExcludedFromBackupKey on the app's PHI directories (drift DB,
    // document blobs, feedback outbox, captures) to match Android's
    // allowBackup="false" posture. Invoked once at startup from main.dart.
    BackupExclusionBridge.register(with: engineBridge.pluginRegistry)
    // `holdclose/document_import` MethodChannel — the native document
    // picker behind Settings → "Restore from backup" (no file_picker
    // package). Vends a chosen JSON backup's bytes to Dart.
    DocumentPickerBridge.register(with: engineBridge.pluginRegistry)
  }
}

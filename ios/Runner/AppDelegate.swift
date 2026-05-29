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
    // BUILD_SPEC.md Phase 9.3 — `careblazers/tts` MethodChannel handler.
    // Hands speak/cancel/availableVoices off to TTSBridge.swift, which
    // owns the ORTSession + AVAudioEngine.
    TTSBridge.register(with: engineBridge.pluginRegistry)
  }
}

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
    registerBundledTtsStub(with: engineBridge.pluginRegistry)
  }

  // BUILD_SPEC.md Phase 9.2 — `careblazers/tts` MethodChannel contract.
  // This is the stub: `speak`/`cancel` succeed immediately and
  // `availableVoices` returns an empty list. Phase 9.3 replaces this
  // with the ORTSession + CoreML execution provider wiring + AVAudioEngine
  // playback.
  private func registerBundledTtsStub(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "CareblazersBundledTTS") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "careblazers/tts",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "speak", "cancel":
        result(nil)
      case "availableVoices":
        result([] as [[String: Any]])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

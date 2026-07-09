import Flutter
import Foundation
import UIKit
import UniformTypeIdentifiers

// `holdclose/document_import` MethodChannel — lets "Restore from backup"
// (Settings → Your data) pull a previously-exported Holdclose JSON backup
// back in. There's no `file_picker` package in the app (no new dependency
// posture), so this wraps `UIDocumentPickerViewController` directly and hands
// the chosen file's bytes to Dart.
//
// The Dart contract (`lib/services/data_exporter.dart`, RealDataFilePicker):
//   pickJson() → Future<Uint8List?>   (null when the caregiver cancelled)
enum DocumentPickerBridge {

    static let channelName = "holdclose/document_import"

    // Strong-held while a pick is in flight; UIDocumentPicker's delegate is
    // weak, so without this the coordinator would deallocate before the
    // caregiver taps a file.
    private static var activeDelegate: PickerDelegate?

    static func register(with registry: FlutterPluginRegistry) {
        guard let registrar = registry.registrar(forPlugin: "HoldcloseDocumentImport") else {
            return
        }
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "pickJson":
                presentPicker(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func presentPicker(result: @escaping FlutterResult) {
        // JSON, plus a plain-text fallback for backups shared without a UTI.
        let types: [UTType] = [.json, .plainText]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.allowsMultipleSelection = false

        let delegate = PickerDelegate { data in
            // One-shot: release the retained delegate now that we've answered.
            activeDelegate = nil
            if let data = data {
                result(FlutterStandardTypedData(bytes: data))
            } else {
                // Cancelled or unreadable — null tells Dart "nothing picked".
                result(nil)
            }
        }
        activeDelegate = delegate
        picker.delegate = delegate

        guard let presenter = topViewController() else {
            activeDelegate = nil
            result(nil)
            return
        }
        presenter.present(picker, animated: true)
    }

    /// Walk to the front-most presented controller so the picker isn't
    /// swallowed by a modal already on screen (the settings sheet, etc.).
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Reads the picked file's bytes (using the security-scoped resource the
/// document picker vends) and reports them back exactly once.
private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: (Data?) -> Void
    private var answered = false

    init(completion: @escaping (Data?) -> Void) {
        self.completion = completion
    }

    private func finish(_ data: Data?) {
        guard !answered else { return }
        answered = true
        completion(data)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else {
            finish(nil)
            return
        }
        // Files vended by the picker are security-scoped — access must be
        // bracketed by start/stop or the read fails with a permission error.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try? Data(contentsOf: url)
        finish(data)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }
}

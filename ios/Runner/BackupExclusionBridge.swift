import Flutter
import Foundation

// Matches Android's `allowBackup="false"` posture for the plaintext PHI the
// app keeps on device (the drift SQLite DB, scanned document blobs,
// voice-note / photo captures, and the feedback outbox). iOS has no single
// manifest switch, so this small MethodChannel (no plugin) sets
// `URLResourceKey.isExcludedFromBackupKey` on the two container directories
// every one of those files lands in — Application Support (drift DB +
// document blobs) and Documents (feedback outbox + captures) — so iCloud /
// iTunes backups never carry a copy of the loved one's health data off the
// device. It also raises the on-disk file-protection class to
// `.completeUntilFirstUserAuthentication` where the OS allows, so the files
// stay encrypted at rest until the device is first unlocked after boot.
//
// The Dart contract (`lib/main.dart`, `_excludeIosDataFromBackup`):
//   excludeDataFromBackup() → Future<void>   (best-effort; never throws to Dart)
enum BackupExclusionBridge {

    static let channelName = "holdclose/backup_exclusion"

    /// Registers the MethodChannel against a plugin registry. Called from
    /// AppDelegate once the implicit Flutter engine boots.
    static func register(with registry: FlutterPluginRegistry) {
        guard let registrar = registry.registrar(forPlugin: "HoldcloseBackupExclusion") else {
            return
        }
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "excludeDataFromBackup":
                applyExclusion()
                // Best-effort: a failure to flip a flag on one file must never
                // surface to the caregiver, so we always resolve success.
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Exclude the two container directories the app writes PHI into from
    /// backup, and raise their file-protection class. Each step is guarded so
    /// a missing directory (nothing written yet) or an unsupported protection
    /// class is a silent no-op rather than an error.
    private static func applyExclusion() {
        let fm = FileManager.default
        let containers: [FileManager.SearchPathDirectory] = [
            .applicationSupportDirectory, // drift SQLite DB + document blobs
            .documentDirectory,           // feedback outbox + voice-note / photo captures
        ]
        for container in containers {
            guard let url = try? fm.url(
                for: container,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ) else {
                continue
            }
            exclude(url)
            protect(url)
        }
    }

    /// Set `isExcludedFromBackupKey` on [url]. Setting it on a directory
    /// excludes the whole subtree, so future files land already-excluded.
    private static func exclude(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    /// Raise the file-protection class to
    /// `.completeUntilFirstUserAuthentication` (readable after the first
    /// post-boot unlock, encrypted at rest before that). `.complete` would
    /// make the DB unreadable while the phone is locked — which the sync poll
    /// and notification handlers need — so we stop one notch short.
    private static func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

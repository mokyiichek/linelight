import Foundation

/// Launch-at-login via a plain LaunchAgent plist.
///
/// Deliberately not `SMAppService` — that needs a signed bundle, and LineLight
/// is built locally without a developer certificate.
enum LaunchAtLogin {

    static let label = "com.mok.linelight"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func set(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    private static func enable() {
        let exe = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
        }
    }

    private static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}

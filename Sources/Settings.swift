import Foundation

/// User-tunable settings, persisted in UserDefaults.
enum Settings {
    private static let d = UserDefaults.standard

    private enum Key {
        static let speedInterval  = "speedIntervalMinutes"
        static let pingInterval   = "pingIntervalSeconds"
        static let pingHost       = "pingHost"
        static let greenMbps      = "greenMbps"
        static let yellowMbps     = "yellowMbps"
        static let slowPingMs     = "slowPingMs"
        static let barMode        = "barMode"      // "speed" | "ping" | "none"
        static let testSeconds    = "testSeconds"
        static let watchInterval  = "watchIntervalSeconds"
        static let flashWhenDown  = "flashWhenDown"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.speedInterval: 10,     // full fast.com test every 10 minutes
            Key.pingInterval: 60,      // lightweight ping every 60 seconds
            Key.pingHost: "1.1.1.1",
            Key.greenMbps: 25.0,       // >= 25 Mbps  -> green
            Key.yellowMbps: 5.0,       // 5 - 25 Mbps -> yellow, < 5 -> red
            Key.slowPingMs: 150.0,     // ping above this downgrades green -> yellow
            Key.barMode: "speed",
            Key.testSeconds: 8.0,      // how long the download sample runs
            Key.watchInterval: 3,      // fast liveness probe; 0 turns it off
            Key.flashWhenDown: true,   // blink the dot while the line is down
        ])
    }

    static var speedIntervalMinutes: Int {
        get { d.integer(forKey: Key.speedInterval) }
        set { d.set(newValue, forKey: Key.speedInterval) }
    }

    static var pingIntervalSeconds: Int {
        get { d.integer(forKey: Key.pingInterval) }
        set { d.set(newValue, forKey: Key.pingInterval) }
    }

    static var pingHost: String {
        get { d.string(forKey: Key.pingHost) ?? "1.1.1.1" }
        set { d.set(newValue, forKey: Key.pingHost) }
    }

    static var greenMbps: Double {
        get { d.double(forKey: Key.greenMbps) }
        set { d.set(newValue, forKey: Key.greenMbps) }
    }

    static var yellowMbps: Double {
        get { d.double(forKey: Key.yellowMbps) }
        set { d.set(newValue, forKey: Key.yellowMbps) }
    }

    static var slowPingMs: Double {
        get { d.double(forKey: Key.slowPingMs) }
        set { d.set(newValue, forKey: Key.slowPingMs) }
    }

    static var barMode: String {
        get { d.string(forKey: Key.barMode) ?? "speed" }
        set { d.set(newValue, forKey: Key.barMode) }
    }

    static var watchIntervalSeconds: Int {
        get { d.integer(forKey: Key.watchInterval) }
        set { d.set(newValue, forKey: Key.watchInterval) }
    }

    static var flashWhenDown: Bool {
        get { d.bool(forKey: Key.flashWhenDown) }
        set { d.set(newValue, forKey: Key.flashWhenDown) }
    }

    static var testSeconds: Double {
        get { d.double(forKey: Key.testSeconds) }
        set { d.set(newValue, forKey: Key.testSeconds) }
    }
}

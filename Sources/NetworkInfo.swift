import Foundation

/// What the Mac is connected through right now — the Wi-Fi network name when
/// macOS will hand it over, otherwise the name of the network service.
///
/// Recent macOS releases treat the SSID as location data and withhold it from
/// apps without Location Services permission. Rather than make the user grant
/// that just to see a label, this asks nicely and falls back to the service
/// name ("Wi-Fi", "iPhone USB", "USB 10/100/1000 LAN"), which is never gated.
enum NetworkInfo {

    /// e.g. "Unifi_5G", or "Wi-Fi (en0)" when the SSID is withheld.
    static func current() -> String? {
        guard let iface = primaryInterface() else { return nil }
        if let ssid = ssid(for: iface) { return ssid }
        if let service = serviceName(for: iface) { return "\(service) (\(iface))" }
        return iface
    }

    // MARK: - Pieces

    /// The interface carrying the default route — the one actually in use.
    private static func primaryInterface() -> String? {
        guard let out = run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                let v = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    private static func ssid(for iface: String) -> String? {
        // ipconfig is the least restricted of the three; still returns the SSID
        // on some releases where the others redact it.
        if let out = run("/usr/sbin/ipconfig", ["getsummary", iface]) {
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("SSID :") else { continue }
                let v = t.dropFirst("SSID :".count).trimmingCharacters(in: .whitespaces)
                if isUsable(v) { return v }
            }
        }

        if let out = run("/usr/sbin/networksetup", ["-getairportnetwork", iface]),
           let r = out.range(of: "Current Wi-Fi Network: ") {
            let v = String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsable(v) { return v }
        }
        return nil
    }

    private static func isUsable(_ s: String) -> Bool {
        !s.isEmpty && s != "<redacted>" && !s.lowercased().contains("not associated")
    }

    /// Walks `networksetup -listnetworkserviceorder`, which pairs each service
    /// name with its device:
    ///
    ///     (1) Wi-Fi
    ///     (Hardware Port: Wi-Fi, Device: en0)
    private static func serviceName(for iface: String) -> String? {
        guard let out = run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) else { return nil }
        var pending: String?
        for line in out.split(separator: "\n") {
            let t = String(line).trimmingCharacters(in: .whitespaces)
            if t.contains("Device: \(iface))") { return pending }
            if t.hasPrefix("("), !t.contains("Hardware Port"), let close = t.firstIndex(of: ")") {
                pending = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

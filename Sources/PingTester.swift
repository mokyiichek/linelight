import Foundation

/// Cheap reachability + latency check.
///
/// Uses the system `ping` binary (setuid, so no special entitlements needed).
/// If ICMP is blocked on the network, falls back to timing a TCP handshake
/// against Cloudflare DNS on port 443.
enum PingTester {

    struct Result {
        let reachable: Bool
        let milliseconds: Double?
    }

    static func run(host: String, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            if let ms = icmp(host: host, count: 3, timeoutSeconds: 3) {
                DispatchQueue.main.async { completion(Result(reachable: true, milliseconds: ms)) }
                return
            }
            if let ms = tcpHandshake(host: host, port: 443, timeout: 3)
                ?? tcpHandshake(host: "1.1.1.1", port: 443, timeout: 3) {
                DispatchQueue.main.async { completion(Result(reachable: true, milliseconds: ms)) }
                return
            }
            DispatchQueue.main.async { completion(Result(reachable: false, milliseconds: nil)) }
        }
    }

    // MARK: - ICMP

    private static func icmp(host: String, count: Int, timeoutSeconds: Int) -> Double? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/ping")
        proc.arguments = ["-c", "\(count)", "-t", "\(timeoutSeconds)", host]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do { try proc.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return nil }

        // round-trip min/avg/max/stddev = 8.123/9.456/11.001/1.002 ms
        guard let re = try? NSRegularExpression(
            pattern: #"=\s*[\d.]+/([\d.]+)/"#) else { return nil }
        let range = NSRange(out.startIndex..., in: out)
        guard let m = re.firstMatch(in: out, range: range),
              let r = Range(m.range(at: 1), in: out) else { return nil }
        return Double(out[r])
    }

    // MARK: - TCP fallback

    private static func tcpHandshake(host: String, port: UInt16, timeout: Int) -> Double? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let start = CFAbsoluteTimeGetCurrent()
        guard connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else { return nil }
        return (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    }
}

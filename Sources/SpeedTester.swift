import Foundation

/// Measures download throughput using Netflix's fast.com infrastructure.
///
/// fast.com hands out a short-lived list of CDN target URLs from
/// `api.fast.com` once you present the token embedded in its web app.
/// We scrape that token on first use (with a known-good fallback), ask for a
/// handful of targets, then download from them in parallel for a few seconds
/// and divide bytes by elapsed time.
final class SpeedTester: NSObject, URLSessionDataDelegate {

    /// Token baked into the fast.com web app. Used if scraping fails.
    private static let fallbackToken = "YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm"
    private static var cachedToken: String?

    private var session: URLSession?
    private var bytes: Int64 = 0
    private var firstByteAt: CFAbsoluteTime?
    private var lastByteAt: CFAbsoluteTime?
    private var finished = false
    private var completion: ((Double?) -> Void)?

    private let queue = OperationQueue()

    override init() {
        super.init()
        queue.maxConcurrentOperationCount = 1   // serialise delegate callbacks
    }

    // MARK: - Public

    /// Runs a download test. Calls back on the main queue with Mbps, or nil if
    /// the line looks dead / the test could not be completed.
    func run(seconds: Double, completion: @escaping (Double?) -> Void) {
        self.completion = completion
        Self.fetchTargets { [weak self] urls in
            guard let self = self else { return }
            guard let urls = urls, !urls.isEmpty else {
                self.finish(nil)
                return
            }
            self.startDownload(urls: urls, seconds: seconds)
        }
    }

    // MARK: - Target discovery

    private static func fetchTargets(_ done: @escaping ([URL]?) -> Void) {
        resolveToken { token in
            var comps = URLComponents(string: "https://api.fast.com/netflix/speedtest/v2")!
            comps.queryItems = [
                URLQueryItem(name: "https", value: "true"),
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "urlCount", value: "5"),
            ]
            guard let url = comps.url else { done(nil); return }

            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard
                    let data = data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let targets = json["targets"] as? [[String: Any]]
                else { done(nil); return }

                let urls = targets.compactMap { $0["url"] as? String }.compactMap(URL.init(string:))
                done(urls.isEmpty ? nil : urls)
            }.resume()
        }
    }

    private static func resolveToken(_ done: @escaping (String) -> Void) {
        if let t = cachedToken { done(t); return }

        var req = URLRequest(url: URL(string: "https://fast.com/")!)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard
                let data = data,
                let html = String(data: data, encoding: .utf8),
                let scriptName = firstMatch(in: html, pattern: #"app-[a-z0-9]+\.js"#),
                let scriptURL = URL(string: "https://fast.com/" + scriptName)
            else { done(fallbackToken); return }

            var r2 = URLRequest(url: scriptURL)
            r2.timeoutInterval = 10
            URLSession.shared.dataTask(with: r2) { d2, _, _ in
                guard
                    let d2 = d2,
                    let js = String(data: d2, encoding: .utf8),
                    let token = firstMatch(in: js, pattern: #"token:"([a-zA-Z0-9]+)""#, group: 1)
                else { done(fallbackToken); return }
                cachedToken = token
                done(token)
            }.resume()
        }.resume()
    }

    private static func firstMatch(in text: String, pattern: String, group: Int = 0) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard
            let m = re.firstMatch(in: text, range: range),
            let r = Range(m.range(at: group), in: text)
        else { return nil }
        return String(text[r])
    }

    // MARK: - Measurement

    private func startDownload(urls: [URL], seconds: Double) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = seconds + 10
        config.httpMaximumConnectionsPerHost = urls.count
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session

        for url in urls {
            var req = URLRequest(url: url)
            req.timeoutInterval = seconds + 10
            session.dataTask(with: req).resume()
        }

        // Hard stop: sample window starts at the first byte, so allow a little
        // head-room for connection setup.
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 6) { [weak self] in
            self?.stopAndReport()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.scheduleStopFromFirstByte(seconds: seconds)
        }
    }

    private func scheduleStopFromFirstByte(seconds: Double) {
        queue.addOperation { [weak self] in
            guard let self = self, !self.finished else { return }
            guard let first = self.firstByteAt else {
                // Nothing arrived yet — check again shortly.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.scheduleStopFromFirstByte(seconds: seconds)
                }
                return
            }
            let remaining = max(0, seconds - (CFAbsoluteTimeGetCurrent() - first))
            DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.stopAndReport()
            }
        }
    }

    private func stopAndReport() {
        queue.addOperation { [weak self] in
            guard let self = self, !self.finished else { return }
            let mbps: Double?
            if let first = self.firstByteAt, let last = self.lastByteAt, self.bytes > 0 {
                let elapsed = max(0.25, last - first)
                mbps = (Double(self.bytes) * 8.0) / elapsed / 1_000_000.0
            } else {
                mbps = nil
            }
            self.finish(mbps)
        }
    }

    private func finish(_ mbps: Double?) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        session = nil
        let cb = completion
        completion = nil
        DispatchQueue.main.async { cb?(mbps) }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let now = CFAbsoluteTimeGetCurrent()
        if firstByteAt == nil {
            firstByteAt = now
            bytes = 0          // ignore whatever arrived during connection setup
        }
        bytes += Int64(data.count)
        lastByteAt = now
    }
}

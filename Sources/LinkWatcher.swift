import Foundation
import Network

/// A fast liveness watch, separate from the latency ping.
///
/// Two signals feed it. `NWPathMonitor` reports the moment the Mac loses its
/// route — Wi-Fi dropping, cable pulled — which needs no polling at all. That
/// misses the more common case where the router is fine but the line behind it
/// is dead, so a cheap TCP handshake runs every few seconds as well.
///
/// One failed probe is not a verdict; packets go missing on healthy links. It
/// takes two in a row to call the line down.
final class LinkWatcher {

    /// Called on the main queue, only when the verdict changes.
    var onChange: ((Bool) -> Void)?

    private(set) var reachable = true

    var host = "1.1.1.1"
    /// Seconds between probes; 0 turns the polling off and leaves only the
    /// interface-level monitor.
    var interval = 3
    var failuresBeforeDown = 2

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.mok.linelight.watch")
    private var timer: DispatchSourceTimer?
    private var failures = 0
    private var started = false

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if path.status == .satisfied {
                self.probe()                 // route is back — confirm for real
            } else {
                self.failures = self.failuresBeforeDown
                self.report(false)           // no route at all: no doubt about it
            }
        }
        monitor.start(queue: queue)
        schedule()
    }

    /// Picks up a changed interval or host.
    func reschedule() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.scheduleLocked()
        }
    }

    private func schedule() {
        queue.async { [weak self] in self?.scheduleLocked() }
    }

    private func scheduleLocked() {
        guard interval > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(interval),
                   repeating: .seconds(interval),
                   leeway: .milliseconds(400))
        t.setEventHandler { [weak self] in self?.probe() }
        t.resume()
        timer = t
    }

    // MARK: - Probing

    private func probe() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if PingTester.reachableQuickly(host: self.host, timeout: 2) {
                self.failures = 0
                self.report(true)
            } else {
                self.failures += 1
                if self.failures >= self.failuresBeforeDown { self.report(false) }
            }
        }
    }

    private func report(_ ok: Bool) {
        guard ok != reachable else { return }
        reachable = ok
        DispatchQueue.main.async { [weak self] in self?.onChange?(ok) }
    }
}

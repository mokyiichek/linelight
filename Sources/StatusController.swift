import Cocoa

enum LineStatus {
    case unknown, down, slow, ok

    var color: NSColor {
        switch self {
        case .unknown: return .secondaryLabelColor
        case .down:    return .systemRed
        case .slow:    return .systemYellow
        case .ok:      return .systemGreen
        }
    }

    var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .down:    return "Line down"
        case .slow:    return "Slow line"
        case .ok:      return "Line OK"
        }
    }
}

struct Reading {
    let date: Date
    let mbps: Double?
    let pingMs: Double?
    let status: LineStatus
}

final class StatusController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var speedTimer: Timer?
    private var pingTimer: Timer?

    private var status: LineStatus = .unknown
    private var lastMbps: Double?
    private var lastPingMs: Double?
    private var lastSpeedCheck: Date?
    private var lastPingCheck: Date?
    private var testing = false
    private var activeTest: SpeedTester?
    private var history: [Reading] = []

    // MARK: - Lifecycle

    func start() {
        menu.delegate = self
        statusItem.menu = menu
        render()
        rebuildMenu()
        scheduleTimers()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        runPing()
        runSpeedTest()
    }

    @objc private func systemDidWake() {
        runPing()
        runSpeedTest()
    }

    private func scheduleTimers() {
        speedTimer?.invalidate()
        pingTimer?.invalidate()

        let speedSecs = Double(max(1, Settings.speedIntervalMinutes)) * 60.0
        speedTimer = Timer.scheduledTimer(withTimeInterval: speedSecs, repeats: true) { [weak self] _ in
            self?.runSpeedTest()
        }
        speedTimer?.tolerance = 15

        let pingSecs = Double(max(10, Settings.pingIntervalSeconds))
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingSecs, repeats: true) { [weak self] _ in
            self?.runPing()
        }
        pingTimer?.tolerance = 5
    }

    // MARK: - Checks

    private func runPing() {
        let wasDown = (status == .down)
        PingTester.run(host: Settings.pingHost) { [weak self] result in
            guard let self = self else { return }
            self.lastPingMs = result.milliseconds
            self.lastPingCheck = Date()
            if !result.reachable {
                self.lastMbps = nil          // a dead line invalidates the old number
            }
            self.evaluate(record: false)

            // Line just came back — get a fresh speed reading straight away
            // rather than waiting out the rest of the interval.
            if wasDown && result.reachable {
                self.runSpeedTest()
            }
        }
    }

    @objc func runSpeedTest() {
        guard !testing else { return }
        testing = true
        render()

        let tester = SpeedTester()
        activeTest = tester                 // keep it alive for the whole test

        var settled = false
        let settle: (Double?) -> Void = { [weak self] mbps in
            guard let self = self, !settled else { return }
            settled = true
            self.activeTest = nil
            self.testing = false
            self.lastMbps = mbps
            self.lastSpeedCheck = Date()
            self.evaluate(record: true)
        }

        tester.run(seconds: Settings.testSeconds) { settle($0) }

        // Watchdog — never leave the menu bar stuck showing "testing".
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { settle(nil) }
    }

    @objc func checkNow() {
        runPing()
        runSpeedTest()
    }

    // MARK: - Status logic

    private func evaluate(record: Bool) {
        let reachable = lastPingMs != nil
        let newStatus: LineStatus

        if !reachable {
            newStatus = .down
        } else if let mbps = lastMbps {
            if mbps < Settings.yellowMbps {
                newStatus = .down
            } else if mbps < Settings.greenMbps {
                newStatus = .slow
            } else if let p = lastPingMs, p > Settings.slowPingMs {
                newStatus = .slow
            } else {
                newStatus = .ok
            }
        } else {
            // Reachable, but no usable speed sample yet.
            newStatus = lastSpeedCheck == nil ? .unknown : .slow
        }

        status = newStatus

        if record {
            history.insert(Reading(date: Date(), mbps: lastMbps,
                                   pingMs: lastPingMs, status: newStatus), at: 0)
            if history.count > 24 { history.removeLast(history.count - 24) }
        }

        persistState()
        render()
    }

    /// Mirrors the current reading into UserDefaults, so the last known state
    /// survives a restart and can be inspected with `defaults read`.
    private func persistState() {
        let d = UserDefaults.standard
        d.set(status.label, forKey: "lastStatus")
        d.set(lastMbps ?? -1, forKey: "lastMbps")
        d.set(lastPingMs ?? -1, forKey: "lastPingMs")
        d.set(Date().description, forKey: "lastUpdated")
        d.set(testing, forKey: "testing")
    }

    // MARK: - Menu bar rendering

    private func render() {
        guard let button = statusItem.button else { return }

        let dot = NSMutableAttributedString(
            string: "●",
            attributes: [
                .foregroundColor: testing ? NSColor.secondaryLabelColor : status.color,
                .font: NSFont.systemFont(ofSize: 11),
                .baselineOffset: 0.5,
            ])

        let value = barValueText()
        if !value.isEmpty {
            dot.append(NSAttributedString(
                string: " " + value,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]))
        }

        button.attributedTitle = dot
        button.toolTip = tooltipText()
    }

    private func barValueText() -> String {
        switch Settings.barMode {
        case "none":
            return ""
        case "ping":
            guard let p = lastPingMs else { return "--" }
            return "\(Int(p.rounded()))"
        default:
            guard status != .down, let m = lastMbps else { return "--" }
            return m >= 10 ? "\(Int(m.rounded()))" : String(format: "%.1f", m)
        }
    }

    private func tooltipText() -> String {
        var parts = [status.label]
        if let m = lastMbps { parts.append(String(format: "%.1f Mbps", m)) }
        if let p = lastPingMs { parts.append("\(Int(p.rounded())) ms") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem(title: testing ? "Testing…" : status.label, action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: testing ? "Testing…" : status.label,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                         .foregroundColor: status.color])
        menu.addItem(header)

        menu.addItem(info(speedLine()))
        menu.addItem(info(pingLine()))
        menu.addItem(info(lastCheckLine()))

        menu.addItem(.separator())

        add("Check Now", #selector(checkNow), key: "r")

        if !history.isEmpty {
            let item = NSMenuItem(title: "Recent Checks", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            for r in history {
                let speed = r.mbps.map { String(format: "%.1f Mbps", $0) } ?? "no line"
                let ping = r.pingMs.map { "\(Int($0.rounded())) ms" } ?? "—"
                let text = "●  \(fmt.string(from: r.date))   \(speed)   \(ping)"
                let styled = NSMutableAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                    ])
                styled.addAttribute(.foregroundColor, value: r.status.color,
                                    range: NSRange(location: 0, length: 1))
                let line = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                line.attributedTitle = styled
                sub.addItem(line)
            }
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(settingsMenuItem())

        let login = add("Open at Login", #selector(toggleLaunchAtLogin), key: "")
        login.state = LaunchAtLogin.isEnabled ? .on : .off

        add("About LineLight", #selector(showAbout), key: "")

        menu.addItem(.separator())
        add("Quit LineLight", #selector(quit), key: "q")
    }

    private func settingsMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let intervals = NSMenuItem(title: "Speed Test Every", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for m in [5, 10, 15, 30, 60] {
            let i = NSMenuItem(title: "\(m) minutes", action: #selector(setSpeedInterval(_:)), keyEquivalent: "")
            i.target = self
            i.tag = m
            i.state = Settings.speedIntervalMinutes == m ? .on : .off
            intervalMenu.addItem(i)
        }
        intervals.submenu = intervalMenu
        sub.addItem(intervals)

        let pings = NSMenuItem(title: "Ping Every", action: nil, keyEquivalent: "")
        let pingMenu = NSMenu()
        for s in [30, 60, 120, 300] {
            let title = s < 60 ? "\(s) seconds" : "\(s / 60) minute\(s == 60 ? "" : "s")"
            let i = NSMenuItem(title: title, action: #selector(setPingInterval(_:)), keyEquivalent: "")
            i.target = self
            i.tag = s
            i.state = Settings.pingIntervalSeconds == s ? .on : .off
            pingMenu.addItem(i)
        }
        pings.submenu = pingMenu
        sub.addItem(pings)

        sub.addItem(.separator())

        let display = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for (key, title) in [("speed", "Speed (Mbps)"), ("ping", "Ping (ms)"), ("none", "Dot only")] {
            let i = NSMenuItem(title: title, action: #selector(setBarMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key
            i.state = Settings.barMode == key ? .on : .off
            displayMenu.addItem(i)
        }
        display.submenu = displayMenu
        sub.addItem(display)

        sub.addItem(.separator())
        let thresholds = NSMenuItem(
            title: "Green ≥ \(Int(Settings.greenMbps)) Mbps · Yellow ≥ \(Int(Settings.yellowMbps)) Mbps",
            action: nil, keyEquivalent: "")
        thresholds.isEnabled = false
        sub.addItem(thresholds)

        root.submenu = sub
        return root
    }

    private func speedLine() -> String {
        guard let m = lastMbps else { return "Speed:  no reading" }
        return String(format: "Speed:  %.1f Mbps", m)
    }

    private func pingLine() -> String {
        guard let p = lastPingMs else { return "Ping:   unreachable" }
        return "Ping:   \(Int(p.rounded())) ms  (\(Settings.pingHost))"
    }

    private func lastCheckLine() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let speed = lastSpeedCheck.map(fmt.string(from:)) ?? "—"
        let ping = lastPingCheck.map(fmt.string(from:)) ?? "—"
        return "Last:   speed \(speed) · ping \(ping)"
    }

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor])
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func setSpeedInterval(_ sender: NSMenuItem) {
        Settings.speedIntervalMinutes = sender.tag
        scheduleTimers()
    }

    @objc private func setPingInterval(_ sender: NSMenuItem) {
        Settings.pingIntervalSeconds = sender.tag
        scheduleTimers()
    }

    @objc private func setBarMode(_ sender: NSMenuItem) {
        Settings.barMode = (sender.representedObject as? String) ?? "speed"
        render()
    }

    @objc private func showAbout() {
        AboutPanel.shared.show()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

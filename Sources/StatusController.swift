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
    let location: String?
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
    private var clientLocation: String?
    private var serverLocation: String?
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
        let settle: (SpeedResult) -> Void = { [weak self] result in
            guard let self = self, !settled else { return }
            settled = true
            self.activeTest = nil
            self.testing = false
            self.lastMbps = result.mbps
            if let c = result.clientLocation { self.clientLocation = c }
            if let s = result.serverLocation { self.serverLocation = s }
            self.lastSpeedCheck = Date()
            self.evaluate(record: true)
        }

        tester.run(seconds: Settings.testSeconds) { settle($0) }

        // Watchdog — never leave the menu bar stuck showing "testing".
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            settle(SpeedResult(mbps: nil, clientLocation: nil, serverLocation: nil))
        }
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
                                   pingMs: lastPingMs, status: newStatus,
                                   location: serverLocation), at: 0)
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
        d.set(clientLocation ?? "", forKey: "clientLocation")
        d.set(serverLocation ?? "", forKey: "serverLocation")
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
        menu.autoenablesItems = false    // readout rows shouldn't render dimmed

        let header = NSMenuItem(title: testing ? "Testing…" : status.label, action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: testing ? "Testing…" : status.label,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                         .foregroundColor: status.color])
        menu.addItem(header)

        menu.addItem(readout("Speed", speedValue()))
        menu.addItem(readout("Ping", pingValue()))
        if let here = clientLocation { menu.addItem(readout("You", here)) }
        if let there = serverLocation { menu.addItem(readout("Server", there)) }
        menu.addItem(readout("Last", lastCheckValue()))

        menu.addItem(.separator())

        add("Check Now", #selector(checkNow), key: "r")

        if !history.isEmpty {
            let item = NSMenuItem(title: "Recent Checks", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false     // these are readouts, not dead items
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            for r in history {
                let speed = r.mbps.map { String(format: "%6.1f Mbps", $0) } ?? "   no line"
                let ping = r.pingMs.map { String(format: "%4ld ms", Int($0.rounded())) } ?? "   —  "
                let where_ = r.location.map { "   \($0)" } ?? ""
                let text = "●  \(fmt.string(from: r.date))   \(speed)   \(ping)\(where_)"
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
                line.isEnabled = true
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

        let green = NSMenuItem(title: "Green Above", action: nil, keyEquivalent: "")
        let greenMenu = NSMenu()
        for v in [10, 25, 50, 100, 200, 500] {
            let i = NSMenuItem(title: "\(v) Mbps", action: #selector(setGreenMbps(_:)), keyEquivalent: "")
            i.target = self
            i.tag = v
            i.state = Int(Settings.greenMbps) == v ? .on : .off
            greenMenu.addItem(i)
        }
        green.submenu = greenMenu
        sub.addItem(green)

        let yellow = NSMenuItem(title: "Yellow Above", action: nil, keyEquivalent: "")
        let yellowMenu = NSMenu()
        for v in [1, 2, 5, 10, 20, 50] {
            let i = NSMenuItem(title: "\(v) Mbps", action: #selector(setYellowMbps(_:)), keyEquivalent: "")
            i.target = self
            i.tag = v
            i.state = Int(Settings.yellowMbps) == v ? .on : .off
            yellowMenu.addItem(i)
        }
        yellow.submenu = yellowMenu
        sub.addItem(yellow)

        let slow = NSMenuItem(title: "Slow Ping Above", action: nil, keyEquivalent: "")
        let slowMenu = NSMenu()
        for v in [50, 100, 150, 200, 300, 500] {
            let i = NSMenuItem(title: "\(v) ms", action: #selector(setSlowPingMs(_:)), keyEquivalent: "")
            i.target = self
            i.tag = v
            i.state = Int(Settings.slowPingMs) == v ? .on : .off
            slowMenu.addItem(i)
        }
        slow.submenu = slowMenu
        sub.addItem(slow)

        root.submenu = sub
        return root
    }

    private func speedValue() -> String {
        guard let m = lastMbps else { return "no reading" }
        return String(format: "%.1f Mbps", m)
    }

    private func pingValue() -> String {
        guard let p = lastPingMs else { return "unreachable" }
        return "\(Int(p.rounded())) ms  (\(Settings.pingHost))"
    }

    private func lastCheckValue() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let speed = lastSpeedCheck.map(fmt.string(from:)) ?? "—"
        let ping = lastPingCheck.map(fmt.string(from:)) ?? "—"
        return "speed \(speed) · ping \(ping)"
    }

    /// A readout row: label padded so the colons line up, full-strength text
    /// rather than the dimmed look a disabled menu item gets.
    private func readout(_ key: String, _ value: String) -> NSMenuItem {
        let text = key.padding(toLength: 6, withPad: " ", startingAt: 0) + "  :  " + value
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: NSColor.labelColor])
        item.isEnabled = true
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

    @objc private func setGreenMbps(_ sender: NSMenuItem) {
        Settings.greenMbps = Double(sender.tag)
        // Green has to sit above yellow, or yellow can never be reached.
        if Settings.yellowMbps >= Settings.greenMbps {
            Settings.yellowMbps = max(1, Settings.greenMbps / 5)
        }
        evaluate(record: false)
    }

    @objc private func setYellowMbps(_ sender: NSMenuItem) {
        Settings.yellowMbps = Double(sender.tag)
        if Settings.yellowMbps >= Settings.greenMbps {
            Settings.greenMbps = Settings.yellowMbps * 5
        }
        evaluate(record: false)
    }

    @objc private func setSlowPingMs(_ sender: NSMenuItem) {
        Settings.slowPingMs = Double(sender.tag)
        evaluate(record: false)
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

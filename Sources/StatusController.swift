import Cocoa

enum LineStatus: String, Codable {
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

struct Reading: Codable {
    let date: Date
    let mbps: Double?
    let pingMs: Double?
    let status: LineStatus
    let location: String?
    let network: String?
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
    private var networkName: String?
    private var history: [Reading] = []

    private let watcher = LinkWatcher()
    private var blinkTimer: Timer?
    private var blinkOn = true

    // MARK: - Lifecycle

    func start() {
        loadHistory()
        menu.delegate = self
        statusItem.menu = menu
        render()
        rebuildMenu()
        scheduleTimers()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        startWatching()
        refreshNetworkName()
        runPing()
        runSpeedTest()
    }

    // MARK: - Fast watch

    private func startWatching() {
        watcher.host = Settings.pingHost
        watcher.interval = Settings.watchIntervalSeconds
        watcher.onChange = { [weak self] reachable in
            self?.linkChanged(reachable: reachable)
        }
        watcher.start()
    }

    /// The watch only ever says up or down. Down is applied straight away so
    /// the menu bar reacts within seconds; coming back triggers a real ping and
    /// a fresh speed reading.
    private func linkChanged(reachable: Bool) {
        if reachable {
            runPing()
            runSpeedTest()
        } else {
            lastPingMs = nil
            lastMbps = nil
            lastPingCheck = Date()
            evaluate(record: false)
        }
    }

    /// While the line is down the dot pulses, so it catches the eye without
    /// needing the menu open.
    private func updateBlink() {
        let wanted = (status == .down) && Settings.flashWhenDown
        if wanted {
            guard blinkTimer == nil else { return }
            blinkOn = true
            let t = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.blinkOn.toggle()
                self.render()
            }
            t.tolerance = 0.1
            blinkTimer = t
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            if !blinkOn { blinkOn = true; render() }
        }
    }

    @objc private func systemDidWake() {
        refreshNetworkName()
        runPing()
        runSpeedTest()
    }

    /// Shelling out costs a few milliseconds, so it happens off the main queue
    /// and only as often as the ping.
    private func refreshNetworkName() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let name = NetworkInfo.current()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.networkName = name
            }
        }
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
            self.refreshNetworkName()
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
                                   location: serverLocation, network: networkName), at: 0)
            if history.count > 24 { history.removeLast(history.count - 24) }
            saveHistory()
        }

        persistState()
        render()
        updateBlink()
    }

    /// History survives restarts and rebuilds, so the graph isn't blank each
    /// time the app relaunches.
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "history")
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "history"),
              let saved = try? JSONDecoder().decode([Reading].self, from: data) else { return }
        history = Array(saved.prefix(24))
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
        d.set(networkName ?? "", forKey: "networkName")
        d.set(testing, forKey: "testing")
    }

    // MARK: - Menu bar rendering

    private func render() {
        guard let button = statusItem.button else { return }

        var dotColor = testing ? NSColor.secondaryLabelColor : status.color
        if status == .down && !blinkOn { dotColor = dotColor.withAlphaComponent(0.18) }

        let dot = NSMutableAttributedString(
            string: "●",
            attributes: [
                .foregroundColor: dotColor,
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
        menu.addItem(readout("Watch", watchValue()))
        if let net = networkName { menu.addItem(readout("Network", net)) }
        if let here = clientLocation { menu.addItem(readout("You", here)) }
        if let there = serverLocation { menu.addItem(readout("Server", there)) }
        menu.addItem(readout("Last", lastCheckValue()))

        menu.addItem(.separator())
        menu.addItem(chartItem())
        menu.addItem(.separator())

        add("Check Now", #selector(checkNow), key: "r")

        if !history.isEmpty {
            let item = NSMenuItem(title: "Recent Checks", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false     // these are readouts, not dead items
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            for r in history {
                let speed = rightAlign(r.mbps.map { String(format: "%.1f Mbps", $0) } ?? "no line", 11)
                let ping = rightAlign(r.pingMs.map { "\(Int($0.rounded())) ms" } ?? "—", 7)
                let net = leftAlign(r.network ?? "—", 12)
                let where_ = r.location ?? ""
                let text = "●  \(fmt.string(from: r.date))   \(speed)   \(ping)   \(net)   \(where_)"
                let styled = NSMutableAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
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

        let watch = NSMenuItem(title: "Watch For Drops", action: nil, keyEquivalent: "")
        let watchMenu = NSMenu()
        for v in [0, 2, 3, 5, 10, 30] {
            let title = v == 0 ? "Off" : "Every \(v) seconds"
            let i = NSMenuItem(title: title, action: #selector(setWatchInterval(_:)), keyEquivalent: "")
            i.target = self
            i.tag = v
            i.state = Settings.watchIntervalSeconds == v ? .on : .off
            watchMenu.addItem(i)
        }
        watch.submenu = watchMenu
        sub.addItem(watch)

        let flash = NSMenuItem(title: "Flash When Down", action: #selector(toggleFlash), keyEquivalent: "")
        flash.target = self
        flash.state = Settings.flashWhenDown ? .on : .off
        sub.addItem(flash)

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

    private func watchValue() -> String {
        let secs = Settings.watchIntervalSeconds
        guard secs > 0 else { return "off" }
        return "every \(secs) s  ·  \(watcher.reachable ? "line up" : "line down")"
    }

    private func lastCheckValue() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let speed = lastSpeedCheck.map(fmt.string(from:)) ?? "—"
        let ping = lastPingCheck.map(fmt.string(from:)) ?? "—"
        return "speed \(speed) · ping \(ping)"
    }

    private func chartItem() -> NSMenuItem {
        let chart = SpeedChartView(frame: NSRect(origin: .zero, size: SpeedChartView.size))
        chart.autoresizingMask = [.width]
        chart.readings = history.reversed()          // oldest on the left
        chart.greenMbps = Settings.greenMbps
        chart.yellowMbps = Settings.yellowMbps
        let item = NSMenuItem()
        item.view = chart
        return item
    }

    /// Pads on the left, so a column of numbers lines up on its right edge.
    private func rightAlign(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    /// Pads on the right and clips, so the column after it starts in one place.
    private func leftAlign(_ s: String, _ width: Int) -> String {
        if s.count == width { return s }
        if s.count < width { return s + String(repeating: " ", count: width - s.count) }
        return String(s.prefix(width - 1)) + "…"
    }

    /// A readout row: label padded so the colons line up, full-strength text
    /// rather than the dimmed look a disabled menu item gets.
    private func readout(_ key: String, _ value: String) -> NSMenuItem {
        let text = key.padding(toLength: 7, withPad: " ", startingAt: 0) + "  :  " + value
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

    @objc private func setWatchInterval(_ sender: NSMenuItem) {
        Settings.watchIntervalSeconds = sender.tag
        watcher.interval = sender.tag
        watcher.reschedule()
    }

    @objc private func toggleFlash() {
        Settings.flashWhenDown = !Settings.flashWhenDown
        updateBlink()
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

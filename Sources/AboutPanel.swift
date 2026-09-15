import Cocoa

/// Top-down coordinates, so the layout code reads the way it looks.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The dark band behind the app icon, matching the icon's own body.
private final class HeroView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [
            NSColor(srgbRed: 0.19, green: 0.22, blue: 0.26, alpha: 1),
            NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1),
        ])?.draw(in: bounds, angle: 270)
    }
}

/// A plain text link — no bezel, no border, just the URL.
private final class LinkLabel: NSTextField {
    var onClick: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // A non-selectable NSTextField normally refuses hits, so clicks would fall
    // straight through to the window behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// A hand-built About window. macOS's `orderFrontStandardAboutPanel` renders
/// its credits as flat, dead text, so the repository link there can't be
/// clicked — this replaces it.
final class AboutPanel: NSObject {

    static let shared = AboutPanel()
    static let repoURL = "https://github.com/mokyiichek/linelight"

    private var window: NSWindow?

    func show() {
        // Rebuilt each time so the intervals and thresholds shown are current.
        window?.close()
        window = makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func makeWindow() -> NSWindow {
        let W: CGFloat = 460, H: CGFloat = 580, HERO: CGFloat = 212

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "About LineLight"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false

        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        win.contentView = root
        root.addSubview(HeroView(frame: NSRect(x: 0, y: 0, width: W, height: HERO)))

        // ---- hero -------------------------------------------------------
        let icon = NSImageView(frame: NSRect(x: (W - 96) / 2, y: 44, width: 96, height: 96))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(icon)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"

        text(root, "LineLight", x: 0, y: 152, w: W, align: .center,
             font: .systemFont(ofSize: 22, weight: .semibold), color: .white)
        text(root, "Version \(version)", x: 0, y: 182, w: W, align: .center,
             font: .systemFont(ofSize: 11), color: NSColor.white.withAlphaComponent(0.55))

        // ---- body -------------------------------------------------------
        text(root, "A traffic light for your internet line.", x: 0, y: HERO + 20, w: W,
             align: .center, font: .systemFont(ofSize: 13), color: .labelColor)

        rule(root, y: HERO + 50, w: W)

        var y = HERO + 66
        caption(root, "HOW IT CHECKS", y: y); y += 20

        let mins = Settings.speedIntervalMinutes
        let secs = Settings.pingIntervalSeconds
        row(root, "Speed", "fast.com download · every \(mins) min", W, y); y += 22
        row(root, "Ping", "\(Settings.pingHost) · every \(secs) s", W, y); y += 30

        caption(root, "WHAT THE COLOURS MEAN", y: y); y += 20

        let g = Int(Settings.greenMbps), ylw = Int(Settings.yellowMbps), sp = Int(Settings.slowPingMs)
        row(root, "Green", "≥ \(g) Mbps and ping ≤ \(sp) ms", W, y, labelColor: .systemGreen); y += 22
        row(root, "Yellow", "\(ylw)–\(g) Mbps, or ping over \(sp) ms", W, y, labelColor: .systemYellow); y += 22
        row(root, "Red", "unreachable, or under \(ylw) Mbps", W, y, labelColor: .systemRed); y += 30

        caption(root, "CREDITS", y: y); y += 20
        row(root, "Author", "Mok Yii Chek", W, y); y += 22
        row(root, "Built with", "Claude (Anthropic)", W, y); y += 22
        row(root, "Licence", "MIT © 2026 Mok Yii Chek", W, y); y += 30

        // ---- link ---------------------------------------------------------
        let link = LinkLabel(labelWithString: Self.repoURL)
        link.font = .systemFont(ofSize: 12)
        link.textColor = .linkColor
        link.alignment = .center
        link.isBordered = false
        link.drawsBackground = false
        link.isSelectable = false
        link.toolTip = "Open the repository on GitHub"
        link.frame = NSRect(x: 32, y: y, width: W - 64, height: 18)
        link.onClick = { [weak self] in self?.openRepo() }
        root.addSubview(link)

        return win
    }

    // MARK: - Builders

    @discardableResult
    private func text(_ parent: NSView, _ s: String, x: CGFloat, y: CGFloat, w: CGFloat,
                      align: NSTextAlignment, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font
        l.textColor = color
        l.alignment = align
        l.lineBreakMode = .byTruncatingTail
        l.frame = NSRect(x: x, y: y, width: w, height: ceil(l.intrinsicContentSize.height))
        parent.addSubview(l)
        return l
    }

    /// Right-aligned label, left-aligned value — a tidy two-column row.
    private func row(_ parent: NSView, _ key: String, _ value: String,
                     _ W: CGFloat, _ y: CGFloat, labelColor: NSColor = .secondaryLabelColor) {
        text(parent, key, x: 32, y: y, w: 96, align: .right,
             font: .systemFont(ofSize: 12), color: labelColor)
        text(parent, value, x: 140, y: y, w: W - 172, align: .left,
             font: .systemFont(ofSize: 12), color: .labelColor)
    }

    private func caption(_ parent: NSView, _ s: String, y: CGFloat) {
        let l = NSTextField(labelWithAttributedString: NSAttributedString(
            string: s,
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.9,
            ]))
        l.frame = NSRect(x: 32, y: y, width: 300, height: 12)
        parent.addSubview(l)
    }

    private func rule(_ parent: NSView, y: CGFloat, w: CGFloat) {
        let line = NSBox(frame: NSRect(x: 32, y: y, width: w - 64, height: 1))
        line.boxType = .separator
        parent.addSubview(line)
    }

    // MARK: - Actions

    @objc private func openRepo() {
        guard let u = URL(string: Self.repoURL) else { return }
        NSWorkspace.shared.open(u)
    }
}

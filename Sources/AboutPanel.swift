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

    // MARK: - Detail block

    private struct Detail {
        let key: String?          // nil = blank spacer line
        let value: String
        let color: NSColor?       // tint for the key only
    }

    private func details() -> [Detail] {
        let g = Int(Settings.greenMbps)
        let y = Int(Settings.yellowMbps)
        let p = Int(Settings.slowPingMs)

        return [
            Detail(key: "Speed", value: "fast.com download · every \(Settings.speedIntervalMinutes) min", color: nil),
            Detail(key: "Ping", value: "\(Settings.pingHost) · every \(Settings.pingIntervalSeconds) s", color: nil),
            Detail(key: nil, value: "", color: nil),
            Detail(key: "Green", value: "\(g) Mbps and above, ping \(p) ms or less", color: .systemGreen),
            Detail(key: "Yellow", value: "\(y) to \(g) Mbps, or ping over \(p) ms", color: .systemYellow),
            Detail(key: "Red", value: "unreachable, or under \(y) Mbps", color: .systemRed),
            Detail(key: nil, value: "", color: nil),
            Detail(key: "Author", value: "Mok Yii Chek", color: nil),
            Detail(key: "Built with", value: "Claude (Anthropic)", color: nil),
            Detail(key: "Licence", value: "MIT © 2026 Mok Yii Chek", color: nil),
        ]
    }

    /// One attributed string with the colons lined up, so the whole block can
    /// be selected and copied in a single drag.
    private func detailText() -> NSAttributedString {
        let rows = details()
        let width = rows.compactMap { $0.key?.count }.max() ?? 0
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        let out = NSMutableAttributedString()
        for (i, row) in rows.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            guard let key = row.key else { continue }

            let padded = key.padding(toLength: width, withPad: " ", startingAt: 0)
            let keyPart = NSMutableAttributedString(
                string: padded,
                attributes: [.font: font, .foregroundColor: row.color ?? NSColor.secondaryLabelColor])
            out.append(keyPart)
            out.append(NSAttributedString(
                string: "  :  ",
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            out.append(NSAttributedString(
                string: row.value,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }

        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        out.addAttribute(.paragraphStyle, value: para,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: - Layout

    private func makeWindow() -> NSWindow {
        let W: CGFloat = 470, HERO: CGFloat = 212

        let block = NSTextField(labelWithAttributedString: detailText())
        block.isSelectable = true
        block.allowsEditingTextAttributes = true
        block.isEditable = false
        block.usesSingleLineMode = false
        block.maximumNumberOfLines = 0
        block.lineBreakMode = .byWordWrapping
        block.cell?.wraps = true
        block.cell?.isScrollable = false
        block.preferredMaxLayoutWidth = W - 72
        let blockH = ceil(block.intrinsicContentSize.height)

        let H = HERO + 50 + 22 + blockH + 26 + 18 + 26

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
        var y = HERO + 20
        text(root, "A traffic light for your internet line.", x: 0, y: y, w: W,
             align: .center, font: .systemFont(ofSize: 13), color: .labelColor)
        y = HERO + 50

        rule(root, y: y, w: W); y += 22

        block.frame = NSRect(x: 36, y: y, width: W - 72, height: blockH)
        root.addSubview(block)
        y += blockH + 26

        rule(root, y: y, w: W); y += 18

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

    private func rule(_ parent: NSView, y: CGFloat, w: CGFloat) {
        let line = NSBox(frame: NSRect(x: 36, y: y, width: w - 72, height: 1))
        line.boxType = .separator
        parent.addSubview(line)
    }

    // MARK: - Actions

    @objc private func openRepo() {
        guard let u = URL(string: Self.repoURL) else { return }
        NSWorkspace.shared.open(u)
    }
}

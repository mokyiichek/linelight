import Cocoa

/// A small speed-over-time chart drawn straight into the menu.
///
/// One series, so no legend — the header names it. The line is neutral ink;
/// each check is a dot in its status colour, which is the thing the app is
/// really about. The green and yellow thresholds sit behind as faint dashed
/// guides, so you can see how close to the edge each reading was.
final class SpeedChartView: NSView {

    /// Oldest first, left to right.
    var readings: [Reading] = [] { didSet { needsDisplay = true } }
    var greenMbps: Double = 25
    var yellowMbps: Double = 5

    static let size = NSSize(width: 330, height: 108)

    private let small = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    private let label = NSFont.systemFont(ofSize: 11, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        // Left margin holds the threshold numbers; top holds the header; the
        // bottom holds the first and last timestamps.
        let plot = NSRect(x: 42, y: 20,
                          width: bounds.width - 42 - 20,
                          height: bounds.height - 20 - 30)

        drawHeader(plot: plot)

        let values = readings.compactMap { $0.mbps }
        guard readings.count >= 2 else {
            text("The graph fills in after two checks",
                 at: NSPoint(x: bounds.midX, y: plot.midY - 6),
                 font: small, color: .tertiaryLabelColor, align: .center)
            return
        }

        let top = max(values.max() ?? 0, greenMbps) * 1.15
        func y(_ v: Double) -> CGFloat { plot.minY + CGFloat(min(v, top) / top) * plot.height }
        func x(_ i: Int) -> CGFloat {
            plot.minX + CGFloat(i) / CGFloat(readings.count - 1) * plot.width
        }

        // Baseline.
        let base = NSBezierPath()
        base.move(to: NSPoint(x: plot.minX, y: plot.minY))
        base.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        base.lineWidth = 1
        NSColor.separatorColor.setStroke()
        base.stroke()

        // Threshold guides — recessive, labelled in muted ink at the left.
        for (value, color) in [(greenMbps, NSColor.systemGreen), (yellowMbps, NSColor.systemYellow)]
        where value > 0 && value < top {
            let gy = y(value)
            let guide = NSBezierPath()
            guide.move(to: NSPoint(x: plot.minX, y: gy))
            guide.line(to: NSPoint(x: plot.maxX, y: gy))
            guide.lineWidth = 1
            guide.setLineDash([3, 3], count: 2, phase: 0)
            color.withAlphaComponent(0.55).setStroke()
            guide.stroke()
            text("\(Int(value))", at: NSPoint(x: plot.minX - 6, y: gy - 6),
                 font: small, color: .secondaryLabelColor, align: .right)
        }

        // Area and line, broken wherever a check failed.
        var runs: [[NSPoint]] = [[]]
        for (i, r) in readings.enumerated() {
            if let m = r.mbps {
                runs[runs.count - 1].append(NSPoint(x: x(i), y: y(m)))
            } else if !(runs.last?.isEmpty ?? true) {
                runs.append([])
            }
        }

        for run in runs where run.count >= 2 {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: run[0].x, y: plot.minY))
            run.forEach { area.line(to: $0) }
            area.line(to: NSPoint(x: run[run.count - 1].x, y: plot.minY))
            area.close()
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            area.fill()

            let line = NSBezierPath()
            line.move(to: run[0])
            run.dropFirst().forEach { line.line(to: $0) }
            line.lineWidth = 2
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            line.stroke()
        }

        // One dot per check, in its status colour. A failed check sits on the
        // baseline in red. The latest reading is drawn slightly larger.
        for (i, r) in readings.enumerated() {
            let latest = i == readings.count - 1
            let radius: CGFloat = latest ? 4.5 : 3.2
            let cy = r.mbps.map(y) ?? plot.minY
            let dot = NSBezierPath(ovalIn: NSRect(x: x(i) - radius, y: cy - radius,
                                                  width: radius * 2, height: radius * 2))
            (r.mbps == nil ? NSColor.systemRed : r.status.color).setFill()
            dot.fill()
        }

        // First and last timestamps under the baseline.
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        text(fmt.string(from: readings[0].date), at: NSPoint(x: plot.minX, y: 4),
             font: small, color: .secondaryLabelColor, align: .left)
        text(fmt.string(from: readings[readings.count - 1].date), at: NSPoint(x: plot.maxX, y: 4),
             font: small, color: .secondaryLabelColor, align: .right)
    }

    private func drawHeader(plot: NSRect) {
        let headerY = bounds.height - 20
        text("Speed", at: NSPoint(x: 14, y: headerY), font: label, color: .labelColor, align: .left)

        let values = readings.compactMap { $0.mbps }
        guard let lo = values.min(), let hi = values.max() else { return }
        let summary = String(format: "low %.0f · high %.0f Mbps", lo, hi)
        text(summary, at: NSPoint(x: plot.maxX, y: headerY + 1),
             font: small, color: .secondaryLabelColor, align: .right)
    }

    private func text(_ s: String, at p: NSPoint, font: NSFont, color: NSColor, align: NSTextAlignment) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        var origin = p
        switch align {
        case .right:  origin.x -= size.width
        case .center: origin.x -= size.width / 2
        default: break
        }
        (s as NSString).draw(at: origin, withAttributes: attrs)
    }
}

import AppKit
import CoreText

// Menu bar design notes
// ---------------------
// * Width is the scarce resource (notched MacBooks hide overflow), so every style is sized
//   for two digits plus "%" and only grows in the rare countdown case.
// * Numbers use monospaced digits, so going from 19% to 20% never shifts the menu bar.
// * Pills work like the battery glyph: the fill knocks the number out of itself, so the
//   number stays readable wherever the fill edge lands, on a light or dark menu bar.
// * Color only appears when it means something (75% orange, 90% red), unless you pick the
//   Claude color mode. Mostly the item looks like any other monochrome menu bar icon.
// * The pace caret under each pill marks how much of the window has elapsed. If the fill
//   is past the caret, you're burning faster than an even pace and will hit the limit
//   before it resets. It hangs below the pill so it never cuts through the digits.
// * At 100% the percentage tells you nothing, so the pill shows time until reset instead.
// * Stale data (no successful fetch for a while) is drawn faded rather than hidden.

/// One limit as drawn in the menu bar.
struct GaugeItem: Equatable {
    var id: String
    var label: String
    var title: String
    var percent: Double
    var pace: Double?
    var severity: Severity
    /// Text inside a pill or in the text style: "42%" or, at 100%, "1h12m".
    var text: String
    /// Text in the stacked style's narrow number column: "42" or "1h".
    var shortText: String

    init(limit: UsageLimit, now: Date, showPace: Bool) {
        id = limit.id
        label = limit.shortLabel
        title = limit.title
        percent = limit.percent
        severity = limit.severity
        pace = showPace && limit.percent < 100 ? limit.elapsedFraction(at: now) : nil
        if limit.percent >= 100, let resetsAt = limit.resetsAt, resetsAt > now {
            let remaining = resetsAt.timeIntervalSince(now)
            text = Fmt.duration(remaining, .compact)
            shortText = Fmt.duration(remaining, .tiny)
        } else {
            text = Fmt.percent(limit.percent)
            shortText = "\(Int(min(max(limit.percent, 0), 999).rounded()))"
        }
    }
}

struct MenuBarModel: Equatable {
    enum State: Equatable { case data, loading, error }

    var state: State = .loading
    var items: [GaugeItem] = []
    var dimmed = false
    var style: MenuBarStyle = .pills
    var colorMode: ColorMode = .warnings
    var showLabels = false

    @MainActor
    static func make(store: UsageStore, style override: MenuBarStyle? = nil) -> MenuBarModel {
        let style = override ?? Prefs.style
        var model = MenuBarModel(state: .data, style: style, colorMode: Prefs.colorMode,
                                 showLabels: Prefs.showLabels || style == .focus)
        guard store.snapshot != nil else {
            model.state = store.error == nil ? .loading : .error
            return model
        }
        model.items = items(from: store.effectiveLimits, style: style, selected: Prefs.metrics,
                            showPace: Prefs.showPace, now: store.now)
        model.dimmed = store.isStale
        return model
    }

    /// Same as `make`, but with sample numbers when there's no real data yet (settings tiles).
    @MainActor
    static func preview(store: UsageStore, style: MenuBarStyle) -> MenuBarModel {
        var model = make(store: store, style: style)
        if model.state != .data || model.items.isEmpty {
            let now = Date()
            model.state = .data
            model.dimmed = false
            model.items = items(from: Samples.snapshot(now: now).limits, style: style,
                                selected: Prefs.metrics, showPace: Prefs.showPace, now: now)
        }
        return model
    }

    static func items(from limits: [UsageLimit], style: MenuBarStyle, selected: [String],
                      showPace: Bool, now: Date) -> [GaugeItem] {
        guard let first = limits.first else { return [] }
        var chosen: [UsageLimit]
        switch style {
        case .focus:
            var best = first
            for limit in limits.dropFirst() where limit.percent > best.percent { best = limit }
            chosen = [best]
        default:
            // Server order (session, week, per-model), not the order you ticked them in.
            chosen = limits.filter { selected.contains($0.id) }
            if chosen.isEmpty { chosen = Array(limits.prefix(2)) }
            if style == .stacked { chosen = Array(chosen.prefix(2)) }
        }
        return chosen.map { GaugeItem(limit: $0, now: now, showPace: showPace) }
    }
}

enum MenuBarRenderer {
    enum Metrics {
        static let edgeInset: CGFloat = 3
        static let itemGap: CGFloat = 5

        static let pillHeight: CGFloat = 15
        static let pillRadius: CGFloat = 4
        static let pillPadX: CGFloat = 5
        static let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        static let labelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        static let labelGap: CGFloat = 3
        static let caretWidth: CGFloat = 4.5
        static let caretHeight: CGFloat = 2.75

        static let stackFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        static let stackLabelFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        static let stackBarWidth: CGFloat = 24
        static let stackBarHeight: CGFloat = 5
        static let stackRowOffset: CGFloat = 4.75

        static let textFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        static let textLabelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        static let textGap: CGFloat = 8
    }

    private typealias M = Metrics

    static func width(for model: MenuBarModel) -> CGFloat {
        ceil(layout(model, ctx: nil, x0: 0, midY: 0, palette: nil))
    }

    static func draw(_ model: MenuBarModel, in ctx: CGContext, bounds: CGRect, appearance: NSAppearance) {
        var palette: Palette?
        appearance.performAsCurrentDrawingAppearance {
            palette = Palette(mode: model.colorMode)
        }
        guard let palette else { return }
        let width = layout(model, ctx: nil, x0: 0, midY: 0, palette: nil)
        let x0 = (bounds.midX - width / 2).rounded()
        ctx.saveGState()
        if model.dimmed {
            ctx.setAlpha(0.45)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        layout(model, ctx: ctx, x0: x0, midY: bounds.midY, palette: palette)
        if model.dimmed { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    static func image(for model: MenuBarModel, appearance: NSAppearance, height: CGFloat = 22) -> NSImage {
        NSImage(size: NSSize(width: width(for: model), height: height), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(model, in: ctx, bounds: rect, appearance: appearance)
            return true
        }
    }

    // MARK: - Layout

    /// Measures (ctx == nil) or draws the model. Returns the total width.
    @discardableResult
    private static func layout(_ model: MenuBarModel, ctx: CGContext?, x0: CGFloat, midY: CGFloat,
                               palette: Palette?) -> CGFloat {
        switch model.state {
        case .loading: return placeholder("–", ctx: ctx, x0: x0, midY: midY, palette: palette)
        case .error: return placeholder("!", ctx: ctx, x0: x0, midY: midY, palette: palette)
        case .data: break
        }
        if model.items.isEmpty { return placeholder("–", ctx: ctx, x0: x0, midY: midY, palette: palette) }
        switch model.style {
        case .pills, .focus: return pills(model, ctx: ctx, x0: x0, midY: midY, palette: palette)
        case .stacked: return stacked(model, ctx: ctx, x0: x0, midY: midY, palette: palette)
        case .text: return text(model, ctx: ctx, x0: x0, midY: midY, palette: palette)
        }
    }

    private static let pillMinTextWidth = TextLine("88%", font: M.pillFont).width

    private static func pills(_ model: MenuBarModel, ctx: CGContext?, x0: CGFloat, midY: CGFloat,
                              palette: Palette?) -> CGFloat {
        var x = x0 + M.edgeInset
        for (index, item) in model.items.enumerated() {
            if index > 0 { x += M.itemGap }
            if model.showLabels {
                let label = TextLine(item.label, font: M.labelFont)
                if let ctx, let palette {
                    label.draw(in: ctx, x: x, baseline: baseline(midY, M.labelFont), color: palette.secondary)
                }
                x += label.width + M.labelGap
            }
            let text = TextLine(item.text, font: M.pillFont)
            let width = (max(text.width, pillMinTextWidth) + 2 * M.pillPadX).rounded(.up)
            if let ctx, let palette {
                let rect = CGRect(x: x, y: midY - M.pillHeight / 2, width: width, height: M.pillHeight)
                drawPill(ctx, rect: rect, item: item, text: text, palette: palette)
            }
            x += width
        }
        return x + M.edgeInset - x0
    }

    private static func stacked(_ model: MenuBarModel, ctx: CGContext?, x0: CGFloat, midY: CGFloat,
                                palette: Palette?) -> CGFloat {
        let items = Array(model.items.prefix(2))
        let numberWidth = items.reduce(TextLine("100", font: M.stackFont).width) {
            max($0, TextLine($1.shortText, font: M.stackFont).width)
        }
        let labelWidth = model.showLabels
            ? items.map { TextLine($0.label, font: M.stackLabelFont).width }.max() ?? 0
            : 0

        var x = x0 + M.edgeInset
        let labelX = x
        if labelWidth > 0 { x += labelWidth + 3 }
        let barX = x
        x += M.stackBarWidth + 3
        let numberX = x
        x += numberWidth

        if let ctx, let palette {
            let centers = items.count == 1 ? [midY] : [midY + M.stackRowOffset, midY - M.stackRowOffset]
            for (item, centerY) in zip(items, centers) {
                if labelWidth > 0 {
                    TextLine(item.label, font: M.stackLabelFont)
                        .draw(in: ctx, x: labelX, baseline: baseline(centerY, M.stackLabelFont), color: palette.secondary)
                }
                let bar = CGRect(x: barX, y: centerY - M.stackBarHeight / 2,
                                 width: M.stackBarWidth, height: M.stackBarHeight)
                drawMiniBar(ctx, rect: bar, item: item, palette: palette)
                let number = TextLine(item.shortText, font: M.stackFont)
                number.draw(in: ctx, x: numberX + numberWidth - number.width,
                            baseline: baseline(centerY, M.stackFont), color: palette.text(for: item.severity))
            }
        }
        return x + M.edgeInset - x0
    }

    private static func text(_ model: MenuBarModel, ctx: CGContext?, x0: CGFloat, midY: CGFloat,
                             palette: Palette?) -> CGFloat {
        var x = x0 + M.edgeInset
        for (index, item) in model.items.enumerated() {
            if index > 0 { x += M.textGap }
            if model.showLabels {
                let label = TextLine(item.label, font: M.textLabelFont)
                if let ctx, let palette {
                    label.draw(in: ctx, x: x, baseline: baseline(midY, M.textFont), color: palette.secondary)
                }
                x += label.width + 2.5
            }
            let value = TextLine(item.text, font: M.textFont)
            if let ctx, let palette {
                value.draw(in: ctx, x: x, baseline: baseline(midY, M.textFont), color: palette.text(for: item.severity))
            }
            x += value.width
        }
        return x + M.edgeInset - x0
    }

    private static func placeholder(_ symbol: String, ctx: CGContext?, x0: CGFloat, midY: CGFloat,
                                    palette: Palette?) -> CGFloat {
        let text = TextLine(symbol, font: M.pillFont)
        let width = (max(text.width, pillMinTextWidth) + 2 * M.pillPadX).rounded(.up)
        if let ctx, let palette {
            let rect = CGRect(x: x0 + M.edgeInset, y: midY - M.pillHeight / 2, width: width, height: M.pillHeight)
            let path = CGPath(roundedRect: rect, cornerWidth: M.pillRadius, cornerHeight: M.pillRadius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(palette.track)
            ctx.fillPath()
            text.draw(in: ctx, x: rect.midX - text.width / 2, baseline: baseline(midY, M.pillFont),
                      color: symbol == "!" ? palette.fg : palette.secondary)
        }
        return width + 2 * M.edgeInset
    }

    // MARK: - Primitives

    /// Baseline that visually centers lining figures on `midY`.
    private static func baseline(_ midY: CGFloat, _ font: NSFont) -> CGFloat {
        ((midY - font.capHeight / 2) * 2).rounded() / 2
    }

    private static func drawPill(_ ctx: CGContext, rect: CGRect, item: GaugeItem, text: TextLine, palette: Palette) {
        let path = CGPath(roundedRect: rect, cornerWidth: M.pillRadius, cornerHeight: M.pillRadius, transform: nil)
        let fraction = min(max(item.percent / 100, 0), 1)
        var fillWidth = ((rect.width * fraction) * 2).rounded() / 2
        if item.percent > 0 { fillWidth = max(fillWidth, 2) }
        let split = rect.minX + fillWidth
        let textX = rect.midX - text.width / 2
        let textBaseline = baseline(rect.midY, M.pillFont)
        let (fillColor, ink) = palette.fill(for: item.severity)

        var paceX: CGFloat?
        if let pace = item.pace, pace > 0.03, pace < 0.97 {
            paceX = (rect.minX + rect.width * pace).rounded()
        }

        // Empty part of the pill: faint track, solid number.
        if split < rect.maxX {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.clip(to: CGRect(x: split, y: rect.minY, width: rect.maxX - split, height: rect.height))
            ctx.setFillColor(palette.track)
            ctx.fill(rect)
            text.draw(in: ctx, x: textX, baseline: textBaseline, color: palette.fg)
            ctx.restoreGState()
        }

        // Filled part: solid fill with the number cut out of it.
        if fillWidth > 0 {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(fillColor)
            ctx.fill(rect)
            switch ink {
            case .knockout:
                ctx.setBlendMode(.destinationOut)
                text.draw(in: ctx, x: textX, baseline: textBaseline, color: .black)
            case .color(let color):
                text.draw(in: ctx, x: textX, baseline: textBaseline, color: color)
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        // Pace marker hangs just below the pill so it never touches the digits.
        if let paceX { drawPaceMarker(ctx, x: paceX, below: rect.minY, color: palette.notch) }
    }

    /// A small caret under the pill pointing up at "how much of the window has passed".
    private static func drawPaceMarker(_ ctx: CGContext, x: CGFloat, below y: CGFloat, color: CGColor) {
        let half = M.caretWidth / 2
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.move(to: CGPoint(x: x - half, y: y - 0.5 - M.caretHeight))
        ctx.addLine(to: CGPoint(x: x + half, y: y - 0.5 - M.caretHeight))
        ctx.addLine(to: CGPoint(x: x, y: y - 0.5))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawMiniBar(_ ctx: CGContext, rect: CGRect, item: GaugeItem, palette: Palette) {
        let radius = rect.height / 2
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let fraction = min(max(item.percent / 100, 0), 1)
        var fillWidth = ((rect.width * fraction) * 2).rounded() / 2
        if item.percent > 0 { fillWidth = max(fillWidth, rect.height) }
        let (fillColor, _) = palette.fill(for: item.severity)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(palette.track)
        ctx.fill(rect)
        ctx.setFillColor(fillColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height))
        if let pace = item.pace, pace > 0.03, pace < 0.97 {
            let x = (rect.minX + rect.width * pace).rounded()
            let tick = CGRect(x: x - 0.5, y: rect.minY, width: 1, height: rect.height)
            if x <= rect.minX + fillWidth {
                ctx.setBlendMode(.destinationOut)
                ctx.setFillColor(.black)
            } else {
                ctx.setFillColor(palette.notch)
            }
            ctx.fill(tick)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// Colors resolved for one appearance (light or dark menu bar).
struct Palette {
    enum Ink {
        /// Punch the text out of the fill so the menu bar shows through.
        case knockout
        case color(CGColor)
    }

    let mode: ColorMode
    let fg: CGColor
    let track: CGColor
    let secondary: CGColor
    let notch: CGColor
    private let warning: CGColor
    private let critical: CGColor
    private let clay: CGColor

    /// Call inside `NSAppearance.performAsCurrentDrawingAppearance` so dynamic colors resolve.
    init(mode: ColorMode) {
        self.mode = mode
        let label = NSColor.labelColor
        fg = label.cgColor
        track = label.withAlphaComponent(0.2).cgColor
        secondary = label.withAlphaComponent(0.6).cgColor
        notch = label.withAlphaComponent(0.75).cgColor
        warning = NSColor.systemOrange.cgColor
        critical = NSColor.systemRed.cgColor
        clay = NSColor.claudeClay.cgColor
    }

    private func color(for severity: Severity) -> CGColor? {
        switch mode.tone(for: severity) {
        case nil: nil
        case .warning: warning
        case .critical: critical
        case .clay: clay
        }
    }

    func fill(for severity: Severity) -> (CGColor, Ink) {
        guard let color = color(for: severity) else { return (fg, .knockout) }
        return (color, .color(Self.ink(on: color)))
    }

    func text(for severity: Severity) -> CGColor {
        guard severity > .normal, let color = color(for: severity) else { return fg }
        return color
    }

    /// Black or white, whichever contrasts more with `color` (WCAG relative luminance).
    static func ink(on color: CGColor) -> CGColor {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let components = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? []
        guard components.count >= 3 else { return CGColor(gray: 1, alpha: 1) }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(components[0]) + 0.7152 * linear(components[1]) + 0.0722 * linear(components[2])
        return luminance > 0.179 ? CGColor(gray: 0, alpha: 0.88) : CGColor(gray: 1, alpha: 1)
    }
}

/// A single line of text drawn with Core Text at an exact baseline.
struct TextLine {
    let line: CTLine
    let width: CGFloat

    init(_ string: String, font: NSFont) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    func draw(in ctx: CGContext, x: CGFloat, baseline: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

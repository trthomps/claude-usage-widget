import AppKit
import SwiftUI

/// Terminal output and offline renderers (previews, app icon).
enum CLI {
    // MARK: - --print / --json

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    static func printUsage(json: Bool) -> Int32 {
        let box = Box<Result<(UsageSnapshot, String?), Error>>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let credential = try CredentialStore.load()
                if credential.isExpired { throw UsageError.credentialsExpired }
                let api = UsageAPI()
                // Both at once, so the cosmetic plan lookup adds no wait (it times out after 10s).
                async let profilePlan = api.fetchPlan(token: credential.accessToken)
                let snapshot = try await api.fetch(token: credential.accessToken)
                let plan = await profilePlan ?? credential.planDescription
                box.value = .success((snapshot, plan))
            } catch {
                box.value = .failure(error)
            }
            done.signal()
        }
        done.wait()

        switch box.value! {
        case .failure(let error):
            let message = (error as? UsageError)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            return 1
        case .success(let (snapshot, plan)):
            if json {
                printJSON(snapshot)
            } else {
                printTable(snapshot, plan: plan)
            }
            return 0
        }
    }

    static func parseFile(_ path: String) -> Int32 {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            printTable(try UsageParser.parse(data), plan: nil)
            return 0
        } catch {
            let message = (error as? UsageError)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            return 1
        }
    }

    private static func printJSON(_ snapshot: UsageSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func printTable(_ snapshot: UsageSnapshot, plan: String?) {
        let now = Date()
        let color = isatty(STDOUT_FILENO) != 0
        func paint(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
        func tint(_ severity: Severity) -> String {
            switch severity {
            case .normal: "38;5;173"
            case .warning: "33"
            case .critical, .limited: "31"
            }
        }

        print(paint("Claude usage", "1") + (plan.map { paint("  ·  \($0)", "2") } ?? ""))
        print("")
        let limits = snapshot.limits.map { $0.effective(at: now) }
        let nameWidth = limits.map(\.title.count).max() ?? 10
        for limit in limits {
            let cells = 24
            let filled = Int((min(max(limit.percent, 0), 100) / 100 * Double(cells)).rounded())
            var bar = Array(repeating: "░", count: cells)
            for i in 0..<filled { bar[i] = "█" }
            let name = limit.title.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let percent = Fmt.percent(limit.percent)
            let padded = String(repeating: " ", count: max(0, 4 - percent.count)) + percent
            var line = "\(name)  \(paint(bar.joined(), tint(limit.severity)))  \(paint(padded, "1"))   \(Fmt.resetPhrase(limit, now: now))"
            switch limit.forecast(at: now) {
            case .runsOut(let interval)?: line += paint("  ⚠ limit in ~\(Fmt.duration(interval)) at this pace", "33")
            case .endsAt(let projected)?: line += paint("  (~\(Int(projected.rounded()))% at reset)", "2")
            case nil: break
            }
            print(line)
        }
        if let extra = snapshot.extra, extra.enabled {
            let used = Fmt.money(extra.used, currency: extra.currency)
            let limit = extra.limit.map { " of " + Fmt.money($0, currency: extra.currency) } ?? ""
            print("")
            print("Extra usage  \(used)\(limit)")
        }
    }

    // MARK: - --render-previews

    @MainActor
    static func renderPreviews(to directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let variants: [(name: String, appearance: NSAppearance.Name, bar: CGColor, ink: CGColor, sheet: CGColor)] = [
            ("dark", .darkAqua, CGColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1),
             CGColor(gray: 0.85, alpha: 1), CGColor(gray: 0.08, alpha: 1)),
            ("light", .aqua, CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1),
             CGColor(gray: 0.2, alpha: 1), CGColor(gray: 1, alpha: 1)),
        ]
        for variant in variants {
            let appearance = NSAppearance(named: variant.appearance)!
            let rep = menuBarSheet(appearance: appearance, bar: variant.bar, ink: variant.ink, sheet: variant.sheet)
            save(rep, to: dir.appendingPathComponent("menubar-\(variant.name).png"))
        }

        let now = Date()
        var snapshot = Samples.snapshot(now: now.addingTimeInterval(-40))
        snapshot.limits[0].percent = 58
        snapshot.limits[0].resetsAt = now.addingTimeInterval(3 * 3600 + 20 * 60)
        let store = UsageStore(preview: snapshot, now: now, plan: "Max · 20x")
        for (name, scheme, background) in [("dark", ColorScheme.dark, Color(white: 0.16)),
                                           ("light", ColorScheme.light, Color(white: 0.97))] {
            let popover = PopoverView(store: store, actions: .none)
                .background(background)
                .environment(\.colorScheme, scheme)
                .environment(\.isSnapshot, true)
            renderSwiftUI(popover, to: dir.appendingPathComponent("popover-\(name).png"))

            let widget = DesktopWidgetView(store: store, actions: .none)
                .background(RoundedRectangle(cornerRadius: 22).fill(background))
                .padding(12)
                .environment(\.colorScheme, scheme)
            renderSwiftUI(widget, to: dir.appendingPathComponent("widget-\(name).png"))
        }
        print("Wrote previews to \(dir.path)")
    }

    private struct PreviewState {
        let name: String
        let session: Double, sessionPace: Double
        let week: Double, weekPace: Double
        var dimmed = false
        var state: MenuBarModel.State = .data
    }

    private struct PreviewRow {
        let name: String
        let style: MenuBarStyle
        let labels: Bool
        let color: ColorMode
    }

    @MainActor
    private static func menuBarSheet(appearance: NSAppearance, bar: CGColor, ink: CGColor, sheet: CGColor) -> NSBitmapImageRep {
        let states = [
            PreviewState(name: "Fresh", session: 4, sessionPace: 0.12, week: 2, weekPace: 0.1),
            PreviewState(name: "Typical", session: 26, sessionPace: 0.45, week: 15, weekPace: 0.35),
            PreviewState(name: "Ahead of pace", session: 58, sessionPace: 0.3, week: 52, weekPace: 0.4),
            PreviewState(name: "Warning", session: 81, sessionPace: 0.6, week: 47, weekPace: 0.55),
            PreviewState(name: "Critical", session: 94, sessionPace: 0.8, week: 77, weekPace: 0.85),
            PreviewState(name: "At limit", session: 100, sessionPace: 0.76, week: 88, weekPace: 0.9),
            PreviewState(name: "Stale", session: 26, sessionPace: 0.45, week: 15, weekPace: 0.35, dimmed: true),
            PreviewState(name: "Loading", session: 0, sessionPace: 0, week: 0, weekPace: 0, state: .loading),
            PreviewState(name: "Error", session: 0, sessionPace: 0, week: 0, weekPace: 0, state: .error),
        ]
        let rows = [
            PreviewRow(name: "Pills", style: .pills, labels: false, color: .warnings),
            PreviewRow(name: "Pills + labels", style: .pills, labels: true, color: .warnings),
            PreviewRow(name: "Stacked", style: .stacked, labels: false, color: .warnings),
            PreviewRow(name: "Stacked + labels", style: .stacked, labels: true, color: .warnings),
            PreviewRow(name: "Focus", style: .focus, labels: true, color: .warnings),
            PreviewRow(name: "Text", style: .text, labels: false, color: .warnings),
            PreviewRow(name: "Text + labels", style: .text, labels: true, color: .warnings),
            PreviewRow(name: "Pills · Claude", style: .pills, labels: false, color: .claude),
            PreviewRow(name: "Pills · Mono", style: .pills, labels: false, color: .monochrome),
        ]

        let now = Date()
        func model(_ row: PreviewRow, _ state: PreviewState) -> MenuBarModel {
            var model = MenuBarModel(state: state.state, dimmed: state.dimmed, style: row.style,
                                     colorMode: row.color, showLabels: row.labels || row.style == .focus)
            if state.state == .data {
                let limits = [
                    Samples.limit(kind: "session", group: "session", percent: state.session,
                                  resetsIn: 5 * 3600 * (1 - state.sessionPace), now: now),
                    Samples.limit(kind: "weekly_all", group: "weekly", percent: state.week,
                                  resetsIn: 7 * 86400 * (1 - state.weekPace), now: now),
                ]
                model.items = MenuBarModel.items(from: limits, style: row.style, selected: Prefs.defaultMetrics,
                                                 showPace: true, now: now)
            }
            return model
        }

        let headerFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let pad: CGFloat = 14, rowHeaderWidth: CGFloat = 104, cellHeight: CGFloat = 24, rowGap: CGFloat = 6
        let titleHeight: CGFloat = 20, cellGap: CGFloat = 6
        let columnWidths = states.map { state in
            max(rows.map { MenuBarRenderer.width(for: model($0, state)) }.max() ?? 0,
                TextLine(state.name, font: headerFont).width) + 14
        }
        let width = pad * 2 + rowHeaderWidth + columnWidths.reduce(0, +) + cellGap * CGFloat(states.count - 1)
        let height = pad * 2 + titleHeight + CGFloat(rows.count) * (cellHeight + rowGap) - rowGap

        return bitmap(size: CGSize(width: width, height: height), scale: 2) { ctx in
            ctx.setFillColor(sheet)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

            var x = pad + rowHeaderWidth
            for (index, state) in states.enumerated() {
                let title = TextLine(state.name, font: headerFont)
                title.draw(in: ctx, x: x + (columnWidths[index] - title.width) / 2,
                           baseline: height - pad - 12, color: ink)
                x += columnWidths[index] + cellGap
            }

            for (rowIndex, row) in rows.enumerated() {
                let y = height - pad - titleHeight - CGFloat(rowIndex + 1) * cellHeight - CGFloat(rowIndex) * rowGap
                TextLine(row.name, font: headerFont).draw(in: ctx, x: pad, baseline: y + 8.5, color: ink)
                var x = pad + rowHeaderWidth
                for (index, state) in states.enumerated() {
                    let cell = CGRect(x: x, y: y, width: columnWidths[index], height: cellHeight)
                    let path = CGPath(roundedRect: cell, cornerWidth: 5, cornerHeight: 5, transform: nil)
                    ctx.addPath(path)
                    ctx.setFillColor(bar)
                    ctx.fillPath()
                    MenuBarRenderer.draw(model(row, state), in: ctx, bounds: cell, appearance: appearance)
                    x += columnWidths[index] + cellGap
                }
            }
        }
    }

    @MainActor
    private static func renderSwiftUI<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("could not render \(url.lastPathComponent)\n".utf8))
            return
        }
        save(NSBitmapImageRep(cgImage: image), to: url)
    }

    // MARK: - --render-icon

    static func renderIconset(to directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
            ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, pixels) in specs {
            let side = CGFloat(pixels)
            let rep = bitmap(size: CGSize(width: side, height: side), scale: 1) { ctx in
                drawAppIcon(ctx, side: side)
            }
            save(rep, to: dir.appendingPathComponent("\(name).png"))
        }
    }

    /// A clay squircle with two gauge pills, echoing the menu bar item.
    private static func drawAppIcon(_ ctx: CGContext, side: CGFloat) {
        let inset = side * 100 / 1024
        let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = rect.width * 0.225
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03,
                      color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.claudeClay.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: srgb, colors: [
            CGColor(srgbRed: 0.90, green: 0.55, blue: 0.43, alpha: 1),
            CGColor(srgbRed: 0.76, green: 0.37, blue: 0.25, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])

        let pillWidth = rect.width * 0.62
        let pillHeight = rect.height * 0.16
        let gap = rect.height * 0.085
        let pillX = rect.midX - pillWidth / 2
        let pills: [(y: CGFloat, fraction: CGFloat)] = [
            (rect.midY + gap / 2, 0.64),
            (rect.midY - gap / 2 - pillHeight, 0.3),
        ]
        for pill in pills {
            let pillRect = CGRect(x: pillX, y: pill.y, width: pillWidth, height: pillHeight)
            let pillRadius = pillHeight * 0.3
            let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)
            ctx.saveGState()
            ctx.addPath(pillPath)
            ctx.clip()
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.3))
            ctx.fill(pillRect)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: pillRect.minX, y: pillRect.minY, width: pillRect.width * pill.fraction, height: pillRect.height))
            ctx.restoreGState()
            // Pace caret under each pill, like the menu bar.
            let caretX = pillRect.minX + pillRect.width * 0.48
            let caretHalf = pillHeight * 0.2
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
            ctx.move(to: CGPoint(x: caretX - caretHalf, y: pillRect.minY - pillHeight * 0.32))
            ctx.addLine(to: CGPoint(x: caretX + caretHalf, y: pillRect.minY - pillHeight * 0.32))
            ctx.addLine(to: CGPoint(x: caretX, y: pillRect.minY - pillHeight * 0.06))
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: - Bitmap helpers

    private static func bitmap(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int((size.width * scale).rounded()),
                                   pixelsHigh: Int((size.height * scale).rounded()),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let ctx = context.cgContext
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func save(_ rep: NSBitmapImageRep, to url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

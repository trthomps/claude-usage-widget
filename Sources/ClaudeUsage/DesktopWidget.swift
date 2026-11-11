import AppKit
import Combine
import SwiftUI

/// A borderless panel that lives on the desktop (above icons, below windows), or floats
/// above everything if you prefer. Drag it anywhere; its position is remembered.
@MainActor
final class DesktopWidgetController {
    private let store: UsageStore
    private let actions: AppActions
    private var panel: NSPanel?
    private var hostingView: NSView?
    private var cancellable: AnyCancellable?
    private var appliedOnTop: Bool?
    private static let autosaveName = "ClaudeUsageDesktopWidget"

    init(store: UsageStore, actions: AppActions) {
        self.store = store
        self.actions = actions
    }

    func sync() {
        if Prefs.showWidget {
            if panel == nil { build() }
            guard let panel else { return }
            if appliedOnTop != Prefs.widgetOnTop { applyLevel(panel) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func build() {
        let hosting = WidgetHostingView(rootView: DesktopWidgetView(store: store, actions: actions))
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = Self.makeBackground(containing: hosting, size: size)

        if !panel.setFrameUsingName(Self.autosaveName) {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24))
        }
        panel.setFrameAutosaveName(Self.autosaveName)

        self.panel = panel
        hostingView = hosting
        applyLevel(panel)
        resizeToFit()

        cancellable = store.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.resizeToFit() } }
    }

    private func applyLevel(_ panel: NSPanel) {
        appliedOnTop = Prefs.widgetOnTop
        panel.level = Prefs.widgetOnTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    /// Grow or shrink with the content, keeping the top-left corner fixed.
    private func resizeToFit() {
        guard let panel, let hostingView else { return }
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0,
              abs(size.width - panel.frame.width) > 0.5 || abs(size.height - panel.frame.height) > 0.5
        else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private static func makeBackground(containing content: NSView, size: NSSize) -> NSView {
        let radius: CGFloat = 22
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: radius)
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Lets a drag anywhere on the widget move the window.
final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct DesktopWidgetView: View {
    @ObservedObject var store: UsageStore
    let actions: AppActions
    @AppStorage(PrefKey.colorMode) private var colorMode: ColorMode = .warnings
    @AppStorage(PrefKey.showPace) private var showPace = true
    @AppStorage(PrefKey.widgetOnTop) private var onTop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Claude")
                    .font(.system(size: 13, weight: .semibold))
                if let plan = store.plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                status
            }

            let limits = store.effectiveLimits
            if limits.isEmpty {
                Text(store.error?.title ?? "Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 168, height: 96)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(limits) { limit in
                        RingGauge(limit: limit, now: store.now,
                                  color: colorMode.uiColor(for: limit.severity), showPace: showPace)
                    }
                }
                .opacity(store.isStale ? 0.55 : 1)
            }
        }
        .padding(16)
        .fixedSize()
        .contextMenu {
            Button("Refresh Now") { actions.refresh() }
            Toggle("Keep Above Other Windows", isOn: $onTop)
            Button("Hide Widget") { Prefs.showWidget = false }
            Divider()
            Button("Settings…") { actions.openSettings() }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let error = store.error {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help(error.message)
        } else if let snapshot = store.snapshot {
            Text(Fmt.ago(snapshot.fetchedAt, now: store.now))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

struct RingGauge: View {
    let limit: UsageLimit
    let now: Date
    let color: Color
    let showPace: Bool

    private let size: CGFloat = 64
    private let lineWidth: CGFloat = 7

    var body: some View {
        let fraction = min(max(limit.percent / 100, 0), 1)
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .inset(by: lineWidth / 2)
                    .stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if showPace, limit.percent < 100, let pace = limit.elapsedFraction(at: now), pace > 0.01, pace < 0.99 {
                    Capsule()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2.5, height: lineWidth + 5)
                        .offset(y: -(size / 2 - lineWidth / 2))
                        .rotationEffect(.degrees(pace * 360))
                }
                Text(Fmt.percent(limit.percent))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(limit.severity >= .critical ? color : .primary)
            }
            .frame(width: size, height: size)

            Text(limit.widgetTitle)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 2) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 7.5, weight: .bold))
                Text(limit.resetsAt.map { Fmt.duration($0.timeIntervalSince(now)) } ?? "—")
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(width: 74)
        .help("\(limit.title) · \(Fmt.resetPhrase(limit, now: now))")
    }
}

import AppKit
import Combine
import SwiftUI

/// Draws the menu bar gauge. Sits on top of the status button and lets clicks through.
final class StatusGaugeView: NSView {
    var model = MenuBarModel() {
        didSet { if model != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Debug.log("draw \(model.style.rawValue) \(model.items.map(\.text)) appearance=\(effectiveAppearance.name.rawValue) bounds=\(bounds) window=\(window?.frame ?? .zero)")
        MenuBarRenderer.draw(model, in: ctx, bounds: bounds, appearance: effectiveAppearance)
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let actions: AppActions
    private let statusItem: NSStatusItem
    private let gaugeView = StatusGaugeView()
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    init(store: UsageStore, actions: AppActions) {
        self.store = store
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: 40)
        super.init()

        statusItem.autosaveName = "ClaudeUsageStatusItem"
        if let button = statusItem.button {
            gaugeView.frame = button.bounds
            gaugeView.autoresizingMask = [.width, .height]
            button.addSubview(gaugeView)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        var popoverActions = actions
        popoverActions.openSettings = { [weak self] in
            self?.popover.performClose(nil)
            actions.openSettings()
        }
        let host = NSHostingController(rootView: PopoverView(store: store, actions: popoverActions))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        update()
    }

    func update() {
        let model = MenuBarModel.make(store: store)
        gaugeView.model = model
        let width = MenuBarRenderer.width(for: model)
        if abs(statusItem.length - width) > 0.5 { statusItem.length = width }

        let summary = tooltip()
        statusItem.button?.toolTip = summary
        statusItem.button?.setAccessibilityLabel(summary)
    }

    private func tooltip() -> String {
        var lines = store.effectiveLimits.map {
            "\($0.title): \(Fmt.percent($0.percent)) · \(Fmt.resetPhrase($0, now: store.now))"
        }
        if let error = store.error { lines.append("⚠︎ \(error.title)") }
        if lines.isEmpty { lines = ["Claude usage: loading…"] }
        if store.isStale, let fetched = store.snapshot?.fetchedAt {
            lines.append("Last updated \(Fmt.ago(fetched, now: store.now))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if store.shouldRefreshOnOpen {
            Task { await store.refresh() }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("Refresh Now", #selector(menuRefresh), key: "r"))
        let widget = item("Show Desktop Widget", #selector(menuToggleWidget))
        widget.state = Prefs.showWidget ? .on : .off
        menu.addItem(widget)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(menuSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Claude Usage", #selector(menuQuit), key: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuRefresh() { actions.refresh() }
    @objc private func menuToggleWidget() { actions.toggleWidget() }
    @objc private func menuSettings() { actions.openSettings() }
    @objc private func menuQuit() { actions.quit() }
}

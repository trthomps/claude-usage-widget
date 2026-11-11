import AppKit
import SwiftUI

@main
enum ClaudeUsageApp {
    @MainActor
    static func main() {
        Prefs.registerDefaults()
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            Claude Usage — menu bar + desktop widget for Claude plan limits

              ClaudeUsage                    run the menu bar app
              ClaudeUsage --print            print usage in the terminal, like /usage
              ClaudeUsage --json             print the parsed snapshot as JSON
              ClaudeUsage --parse FILE       parse a saved API response (for testing)
              ClaudeUsage --render-previews DIR   render menu bar / popover / widget PNGs
              ClaudeUsage --render-icon DIR       render an .iconset for the app icon
            """)
            return
        }
        if args.contains("--print") || args.contains("--json") {
            exit(CLI.printUsage(json: args.contains("--json")))
        }
        if let path = value(after: "--parse", in: args) {
            exit(CLI.parseFile(path))
        }
        if let dir = value(after: "--render-previews", in: args) {
            _ = NSApplication.shared
            CLI.renderPreviews(to: dir)
            return
        }
        if let dir = value(after: "--render-icon", in: args) {
            CLI.renderIconset(to: dir)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

struct AppActions {
    var refresh: () -> Void
    var openSettings: () -> Void
    var toggleWidget: () -> Void
    var quit: () -> Void

    static let none = AppActions(refresh: {}, openSettings: {}, toggleWidget: {}, quit: {})
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusController: StatusItemController?
    private var widgetController: DesktopWidgetController?
    private var settingsController: SettingsWindowController?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = AppActions(
            refresh: { [weak self] in
                guard let self else { return }
                Task { await self.store.refresh(userInitiated: true) }
            },
            openSettings: { [weak self] in self?.showSettings() },
            toggleWidget: { Prefs.showWidget.toggle() },
            quit: { NSApp.terminate(nil) }
        )

        statusController = StatusItemController(store: store, actions: actions)
        widgetController = DesktopWidgetController(store: store, actions: actions)
        widgetController?.sync()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }

        store.start()
    }

    private func preferencesChanged() {
        statusController?.update()
        widgetController?.sync()
        store.preferencesChanged()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Settings. That's the way in
    /// when a menu bar manager has hidden the status item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(store: store)
        }
        settingsController?.show()
    }
}

/// `CLAUDE_USAGE_DEBUG=1` prints diagnostics to stderr.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["CLAUDE_USAGE_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[ClaudeUsage] \(message())\n".utf8))
    }
}

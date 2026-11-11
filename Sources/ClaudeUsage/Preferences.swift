import AppKit
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case pills, stacked, focus, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pills: "Pills"
        case .stacked: "Stacked"
        case .focus: "Focus"
        case .text: "Text"
        }
    }

    var blurb: String {
        switch self {
        case .pills: "A bar behind each percentage."
        case .stacked: "Two mini bars on top of each other, the narrowest option."
        case .focus: "Only the limit closest to running out."
        case .text: "Just the numbers."
        }
    }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case warnings, claude, monochrome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warnings: "Warnings"
        case .claude: "Claude"
        case .monochrome: "Mono"
        }
    }

    var blurb: String {
        switch self {
        case .warnings: "Matches the menu bar until a limit passes 75% (orange) or 90% (red)."
        case .claude: "Claude's clay color, turning red past 90%."
        case .monochrome: "Never colored."
        }
    }

    enum Tone { case warning, critical, clay }

    /// Menu bar fill tone, or nil for "use the menu bar's own text color".
    func tone(for severity: Severity) -> Tone? {
        switch (self, severity) {
        case (.monochrome, _): nil
        case (_, .critical), (_, .limited): .critical
        case (.warnings, .warning): .warning
        case (.warnings, .normal): nil
        case (.claude, _): .clay
        }
    }

    /// Bar and ring color in the popover and desktop widget.
    func uiColor(for severity: Severity) -> Color {
        switch (self, severity) {
        case (.monochrome, _): Color.primary.opacity(0.75)
        case (_, .critical), (_, .limited): .red
        case (.warnings, .warning): .orange
        default: .claudeClay
        }
    }
}

extension NSColor {
    /// Claude's terracotta, #D97757.
    static let claudeClay = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
}

extension Color {
    static let claudeClay = Color(nsColor: .claudeClay)
}

enum PrefKey {
    static let style = "menuBarStyle"
    static let metrics = "menuBarMetrics"
    static let showLabels = "showLabels"
    static let showPace = "showPace"
    static let colorMode = "colorMode"
    static let refreshInterval = "refreshInterval"
    static let showWidget = "showDesktopWidget"
    static let widgetOnTop = "widgetOnTop"
}

/// Typed access to UserDefaults. SwiftUI settings bind to the same keys with @AppStorage.
enum Prefs {
    static let defaultMetrics = ["session", "weekly_all"]
    static var store: UserDefaults { .standard }

    static func registerDefaults() {
        store.register(defaults: [
            PrefKey.style: MenuBarStyle.pills.rawValue,
            PrefKey.metrics: defaultMetrics.joined(separator: ","),
            PrefKey.showLabels: false,
            PrefKey.showPace: true,
            PrefKey.colorMode: ColorMode.warnings.rawValue,
            PrefKey.refreshInterval: 120.0,
            PrefKey.showWidget: false,
            PrefKey.widgetOnTop: false,
        ])
    }

    static var style: MenuBarStyle {
        MenuBarStyle(rawValue: store.string(forKey: PrefKey.style) ?? "") ?? .pills
    }

    static var metrics: [String] {
        (store.string(forKey: PrefKey.metrics) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static var showLabels: Bool { store.bool(forKey: PrefKey.showLabels) }
    static var showPace: Bool { store.bool(forKey: PrefKey.showPace) }

    static var colorMode: ColorMode {
        ColorMode(rawValue: store.string(forKey: PrefKey.colorMode) ?? "") ?? .warnings
    }

    static var refreshInterval: TimeInterval {
        max(30, store.double(forKey: PrefKey.refreshInterval))
    }

    static var showWidget: Bool {
        get { store.bool(forKey: PrefKey.showWidget) }
        set { store.set(newValue, forKey: PrefKey.showWidget) }
    }

    static var widgetOnTop: Bool {
        get { store.bool(forKey: PrefKey.widgetOnTop) }
        set { store.set(newValue, forKey: PrefKey.widgetOnTop) }
    }
}

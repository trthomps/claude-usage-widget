import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let store: UsageStore
    private var window: NSWindow?

    init(store: UsageStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Claude Usage Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(PrefKey.style) private var style: MenuBarStyle = .pills
    @AppStorage(PrefKey.metrics) private var metricsRaw = Prefs.defaultMetrics.joined(separator: ",")
    @AppStorage(PrefKey.showLabels) private var showLabels = false
    @AppStorage(PrefKey.showPace) private var showPace = true
    @AppStorage(PrefKey.colorMode) private var colorMode: ColorMode = .warnings
    @AppStorage(PrefKey.refreshInterval) private var refreshInterval: Double = 120
    @AppStorage(PrefKey.showWidget) private var showWidget = false
    @AppStorage(PrefKey.widgetOnTop) private var widgetOnTop = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(MenuBarStyle.allCases) { candidate in
                        StyleTile(style: candidate, selected: candidate == style,
                                  image: preview(for: candidate), dark: colorScheme == .dark)
                            .onTapGesture { style = candidate }
                    }
                }
                .padding(.vertical, 4)
                Text(style.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Menu bar style")
            }

            Section("Show in menu bar") {
                ForEach(availableMetrics, id: \.id) { metric in
                    Toggle(metric.title, isOn: binding(for: metric.id))
                }
                .disabled(style == .focus)
                if style == .focus {
                    note("Focus always shows whichever limit is closest to running out.")
                } else if style == .stacked {
                    note("Stacked shows the first two limits you pick.")
                }
            }

            Section("Appearance") {
                Toggle("Show labels (5h, 7d)", isOn: $showLabels)
                    .disabled(style == .focus)
                Toggle(isOn: $showPace) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pace marker")
                        note("A small caret under each bar marks how much of the window has passed. If the fill is past it, you're on track to run out before the limit resets.")
                    }
                }
                Picker("Color", selection: $colorMode) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                note(colorMode.blurb)
            }

            Section("Desktop widget") {
                Toggle("Show widget on the desktop", isOn: $showWidget)
                Toggle("Keep it above other windows", isOn: $widgetOnTop)
                    .disabled(!showWidget)
                note("Drag the widget to move it. Right-click it for options.")
            }

            Section("General") {
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    note(loginError).foregroundStyle(.orange)
                }
            }

            Section("Account") {
                LabeledContent("Plan", value: store.plan ?? "—")
                LabeledContent("Login", value: store.credentialSource ?? "Not found")
                if let expires = store.tokenExpiresAt {
                    LabeledContent("Token", value: expires > store.now
                        ? "valid for \(Fmt.duration(expires.timeIntervalSince(store.now)))"
                        : "expired, renews when you next use Claude Code")
                }
                note("Reads Claude Code's existing login (read-only) and asks Anthropic for the same numbers /usage shows. That request is the only thing that leaves your Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 700)
    }

    private struct Metric { let id: String; let title: String }

    private var availableMetrics: [Metric] {
        let limits = store.snapshot?.limits ?? []
        if limits.isEmpty {
            return [Metric(id: "session", title: "Current session"),
                    Metric(id: "weekly_all", title: "Current week (all models)")]
        }
        return limits.map { Metric(id: $0.id, title: $0.title) }
    }

    private var selectedMetrics: [String] {
        metricsRaw.split(separator: ",").map(String.init)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedMetrics.contains(id) },
            set: { enabled in
                var ids = selectedMetrics.filter { $0 != id }
                if enabled { ids.append(id) }
                metricsRaw = ids.joined(separator: ",")
            }
        )
    }

    private func preview(for candidate: MenuBarStyle) -> NSImage {
        // Reading these keeps the tiles in sync when they change.
        _ = (metricsRaw, showLabels, showPace, colorMode)
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        return MenuBarRenderer.image(for: MenuBarModel.preview(store: store, style: candidate),
                                     appearance: appearance)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StyleTile: View {
    let style: MenuBarStyle
    let selected: Bool
    let image: NSImage
    let dark: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: image)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(dark ? Color(white: 0.13) : Color(white: 0.95))
                )
            Text(style.title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: selected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}

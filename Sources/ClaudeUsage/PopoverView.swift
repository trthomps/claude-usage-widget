import SwiftUI

/// The click-through detail view: what `/usage` shows, plus pace and forecast.
struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let actions: AppActions
    @AppStorage(PrefKey.colorMode) private var colorMode: ColorMode = .warnings
    @AppStorage(PrefKey.showPace) private var showPace = true
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            content
                .padding(16)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Usage")
                .font(.system(size: 13, weight: .semibold))
            if let plan = store.plan {
                Text(plan)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer()
            IconButton(systemName: "arrow.clockwise", help: "Refresh now", busy: store.isRefreshing) {
                actions.refresh()
            }
            IconButton(systemName: "gearshape", help: "Settings") {
                actions.openSettings()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let limits = store.effectiveLimits
        if limits.isEmpty {
            EmptyStateView(error: store.error, retry: actions.refresh)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(limits) { limit in
                    LimitRow(limit: limit, now: store.now, colorMode: colorMode, showPace: showPace)
                }
                if let extra = store.snapshot?.extra, extra.enabled {
                    ExtraUsageRow(extra: extra, colorMode: colorMode)
                }
            }
            .opacity(store.isStale ? 0.55 : 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = store.error, store.snapshot != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(footerErrorText(error))
                    .lineLimit(1)
                    .help(error.message)
            } else if let snapshot = store.snapshot {
                Text("Updated \(Fmt.ago(snapshot.fetchedAt, now: store.now))")
            }
            Spacer()
            if snapshot {
                Text("Quit")
            } else {
                Button("Quit") { actions.quit() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func footerErrorText(_ error: UsageError) -> String {
        guard let fetched = store.snapshot?.fetchedAt else { return error.title }
        return "\(error.title) · data from \(Fmt.ago(fetched, now: store.now))"
    }
}

struct LimitRow: View {
    let limit: UsageLimit
    let now: Date
    let colorMode: ColorMode
    let showPace: Bool

    var body: some View {
        let color = colorMode.uiColor(for: limit.severity)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(Fmt.percent(limit.percent))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(limit.severity >= .warning ? color : .primary)
            }
            UsageBar(fraction: limit.percent / 100,
                     pace: showPace && limit.percent < 100 ? limit.elapsedFraction(at: now) : nil,
                     color: color)
                .frame(height: 8)
                .padding(.vertical, 1)
            HStack(spacing: 6) {
                Text(Fmt.resetPhrase(limit, now: now))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                forecast
            }
            .font(.system(size: 11))
            .monospacedDigit()
        }
    }

    @ViewBuilder
    private var forecast: some View {
        switch limit.forecast(at: now) {
        case .runsOut(let interval)?:
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("Limit in ~\(Fmt.duration(interval))")
            }
            .foregroundStyle(.orange)
            .help("At your current rate you'll hit this limit before it resets.")
        case .endsAt(let percent)?:
            Text("~\(Int(percent.rounded()))% at reset")
                .foregroundStyle(.tertiary)
                .help("Where this window ends up at your current rate.")
        case nil:
            EmptyView()
        }
    }
}

/// Horizontal bar with an optional pace tick.
struct UsageBar: View {
    let fraction: Double
    let pace: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: clamped > 0 ? max(height, width * clamped) : 0)
                if let pace, pace > 0.01, pace < 0.99 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2, height: height + 6)
                        .offset(x: min(max(width * pace - 1, 0), width - 2))
                        .help("Even pace: how much of this window has passed. Past this line, you'll run out before it resets.")
                }
            }
        }
    }
}

struct ExtraUsageRow: View {
    let extra: ExtraUsage
    let colorMode: ColorMode

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Extra usage")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Group {
                    if let limit = extra.limit {
                        Text("\(Fmt.money(extra.used, currency: extra.currency)) of \(Fmt.money(limit, currency: extra.currency))")
                    } else {
                        Text(Fmt.money(extra.used, currency: extra.currency))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            }
            if let limit = extra.limit, limit > 0 {
                let percent = extra.used / limit * 100
                UsageBar(fraction: percent / 100, pace: nil,
                         color: colorMode.uiColor(for: Severity(percent: percent)))
                    .frame(height: 5)
            }
        }
    }
}

struct EmptyStateView: View {
    let error: UsageError?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let error {
                Image(systemName: error.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text(error.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(error.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Loading usage…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var busy = false
    let action: () -> Void
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(busy)
    }
}

/// Offscreen renders (README images) can't draw real buttons, so views swap in plain shapes.
private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

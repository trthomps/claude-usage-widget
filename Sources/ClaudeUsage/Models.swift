import Foundation

/// How close a limit is to blocking you. Drives color in the menu bar, popover and widget.
enum Severity: Int, Comparable, Codable {
    case normal = 0
    case warning
    case critical
    case limited

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    init(percent: Double) {
        switch percent {
        case 100...: self = .limited
        case 90..<100: self = .critical
        case 75..<90: self = .warning
        default: self = .normal
        }
    }

    /// Maps the API's `severity` string, when it sends one we recognise.
    init?(server: String?) {
        guard let value = server?.lowercased() else { return nil }
        switch value {
        case "warning", "warn", "approaching", "elevated", "high": self = .warning
        case "critical", "danger", "severe": self = .critical
        case "limited", "exceeded", "blocked", "at_limit", "maxed", "locked": self = .limited
        default: return nil
        }
    }
}

/// One rate-limit window, e.g. the 5-hour session or the weekly cap.
struct UsageLimit: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var group: String
    /// Long name, as /usage shows it: "Current session", "Current week (all models)".
    var title: String
    /// Two-character menu bar label: "5h", "7d", "F".
    var shortLabel: String
    /// Name under a ring in the desktop widget: "Session", "Week", "Fable".
    var widgetTitle: String
    var percent: Double
    var resetsAt: Date?
    var windowDuration: TimeInterval?
    var serverSeverity: String?
    var isActive: Bool

    var severity: Severity {
        max(Severity(percent: percent), Severity(server: serverSeverity) ?? .normal)
    }

    /// The limit as of `now`. Once the reset time passes the window has rolled over,
    /// so we show 0% instead of a stale number until the next fetch lands.
    func effective(at now: Date) -> UsageLimit {
        guard let resetsAt, resetsAt <= now else { return self }
        var copy = self
        copy.percent = 0
        copy.serverSeverity = nil
        if group == "weekly", let duration = windowDuration, duration > 0 {
            var next = resetsAt
            while next <= now { next = next.addingTimeInterval(duration) }
            copy.resetsAt = next
        } else {
            // A new session window only starts with your next message.
            copy.resetsAt = nil
        }
        return copy
    }

    /// How far through the window we are (0...1). This is where usage would sit if it
    /// were spread evenly, which is what the pace marker shows.
    func elapsedFraction(at now: Date) -> Double? {
        guard let resetsAt, let duration = windowDuration, duration > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-duration)
        let fraction = now.timeIntervalSince(start) / duration
        guard fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }

    /// Straight-line projection of the current window at the average rate so far.
    func forecast(at now: Date) -> Forecast? {
        guard percent >= 1, percent < 100,
              let resetsAt, let fraction = elapsedFraction(at: now), let duration = windowDuration
        else { return nil }
        let elapsed = fraction * duration
        guard elapsed >= 15 * 60 else { return nil } // too early to say anything useful
        let rate = percent / elapsed // percent per second
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let projected = percent + rate * remaining
        if projected >= 100 {
            return .runsOut(in: (100 - percent) / rate)
        }
        return .endsAt(percent: projected)
    }
}

enum Forecast: Equatable {
    /// At this rate the limit is hit before the window resets.
    case runsOut(in: TimeInterval)
    /// At this rate the window resets with this much used.
    case endsAt(percent: Double)
}

/// Pay-as-you-go credits used after hitting plan limits.
struct ExtraUsage: Codable, Equatable {
    var used: Double
    var limit: Double?
    var currency: String
    var enabled: Bool
}

struct UsageSnapshot: Codable, Equatable {
    var limits: [UsageLimit]
    var extra: ExtraUsage?
    var fetchedAt: Date
}

/// Turns the API's limit kinds into human names, labels and window lengths.
enum LimitNaming {
    struct Info {
        var id: String
        var title: String
        var short: String
        var widgetTitle: String
        var duration: TimeInterval?
    }

    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86400

    static func describe(kind: String, group: String, scope: String?) -> Info {
        let duration = windowDuration(kind: kind, group: group)
        let scope = scope?.trimmingCharacters(in: .whitespaces)

        if scope == nil || scope?.isEmpty == true {
            switch kind {
            case "session":
                return Info(id: "session", title: "Current session", short: "5h",
                            widgetTitle: "Session", duration: duration ?? 5 * hour)
            case "weekly_all":
                return Info(id: "weekly_all", title: "Current week (all models)", short: "7d",
                            widgetTitle: "Week", duration: duration ?? 7 * day)
            default:
                let name = humanize(kind)
                return Info(id: kind, title: name, short: String(name.prefix(2)),
                            widgetTitle: name, duration: duration)
            }
        }

        let name = scope!
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "_")
        let initial = String(name.prefix(1)).uppercased()
        if group == "weekly" || kind.hasPrefix("weekly") || kind.hasPrefix("seven_day") {
            return Info(id: "weekly:\(slug)", title: "Current week (\(name))", short: initial,
                        widgetTitle: name, duration: duration ?? 7 * day)
        }
        return Info(id: "\(kind):\(slug)", title: "\(humanize(kind)) (\(name))", short: initial,
                    widgetTitle: name, duration: duration)
    }

    static func windowDuration(kind: String, group: String) -> TimeInterval? {
        let k = kind.lowercased(), g = group.lowercased()
        if g == "session" || k.contains("session") || k.contains("five_hour") { return 5 * hour }
        if g == "weekly" || k.contains("weekly") || k.hasPrefix("seven_day") { return 7 * day }
        if g == "daily" || k.contains("daily") { return day }
        return nil
    }

    static func humanize(_ raw: String) -> String {
        let words = raw.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard let first = words.first else { return raw }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }
}

/// Canned data for previews, settings tiles and the preview renderer.
enum Samples {
    static func snapshot(now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            limits: [
                limit(kind: "session", group: "session", percent: 26, resetsIn: 3 * 3600 + 9 * 60, now: now),
                limit(kind: "weekly_all", group: "weekly", percent: 15, resetsIn: 5 * 86400 + 16 * 3600, now: now),
                limit(kind: "weekly_scoped", group: "weekly", scope: "Fable", percent: 4,
                      resetsIn: 5 * 86400 + 16 * 3600, now: now),
            ],
            extra: ExtraUsage(used: 12.4, limit: 200, currency: "USD", enabled: true),
            fetchedAt: now
        )
    }

    static func limit(kind: String, group: String, scope: String? = nil, percent: Double,
                      resetsIn: TimeInterval, now: Date) -> UsageLimit {
        let info = LimitNaming.describe(kind: kind, group: group, scope: scope)
        return UsageLimit(id: info.id, kind: kind, group: group, title: info.title,
                          shortLabel: info.short, widgetTitle: info.widgetTitle, percent: percent,
                          resetsAt: now.addingTimeInterval(resetsIn), windowDuration: info.duration,
                          serverSeverity: nil, isActive: false)
    }
}

import Foundation

enum Fmt {
    static func percent(_ value: Double) -> String {
        "\(Int(min(max(value, 0), 999).rounded()))%"
    }

    enum DurationStyle {
        /// "2h 14m", "5d 16h"
        case long
        /// "2h14m", "13h", "5d16h" — fits inside a menu bar pill
        case compact
        /// "2h", "42m", "5d" — fits the stacked style's number column
        case tiny
    }

    static func duration(_ interval: TimeInterval, _ style: DurationStyle = .long) -> String {
        let total = max(0, Int(interval))
        if total < 60 { return "<1m" }
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let totalHours = total / 3600
        let minutes = (total % 3600) / 60

        switch style {
        case .long:
            if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
            if totalHours > 0 { return minutes > 0 ? "\(totalHours)h \(minutes)m" : "\(totalHours)h" }
            return "\(minutes)m"
        case .compact:
            if days > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
            if totalHours >= 10 { return "\(totalHours)h" }
            if totalHours > 0 { return minutes > 0 ? "\(totalHours)h\(minutes)m" : "\(totalHours)h" }
            return "\(minutes)m"
        case .tiny:
            if days > 0 { return "\(days)d" }
            if totalHours > 0 { return "\(totalHours)h" }
            return "\(minutes)m"
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    private static let dayClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter
    }()

    /// "Resets in 2h 14m · 6:40 PM" or "Resets Tue 7:00 AM · in 5d 16h".
    static func resetPhrase(_ limit: UsageLimit, now: Date) -> String {
        guard let resetsAt = limit.resetsAt else {
            return limit.group == "session" ? "Starts with your next message" : "Not started"
        }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "Resetting…" }
        if remaining < 86400 {
            return "Resets in \(duration(remaining)) · \(clock.string(from: resetsAt))"
        }
        return "Resets \(dayClock.string(from: resetsAt)) · in \(duration(remaining))"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    static func money(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, currency)
    }
}

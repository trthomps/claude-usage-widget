import Foundation

/// Parses `GET /api/oauth/usage`.
///
/// Newer responses carry a structured `limits` array (session, weekly_all, weekly_scoped
/// per model). Older ones only have flat keys (`five_hour`, `seven_day`, `seven_day_opus`, ...).
/// We prefer `limits` and fall back to the flat keys, and ignore everything else, so new
/// fields on the server don't break us.
enum UsageParser {
    static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError.decoding("invalid JSON")
        }
        guard let root = object as? [String: Any] else {
            throw UsageError.decoding("expected a JSON object")
        }

        var limits: [UsageLimit]
        if let array = root["limits"] as? [[String: Any]], !array.isEmpty {
            limits = array.compactMap(parseLimit)
        } else {
            limits = parseLegacy(root)
        }

        // Keep ids unique so SwiftUI lists and preferences stay stable.
        var seen: [String: Int] = [:]
        for index in limits.indices {
            let id = limits[index].id
            if let count = seen[id] {
                seen[id] = count + 1
                limits[index].id = "\(id)#\(count + 1)"
            } else {
                seen[id] = 1
            }
        }

        if limits.isEmpty, root["limits"] == nil, root["five_hour"] == nil {
            throw UsageError.decoding("no usage limits in response")
        }
        return UsageSnapshot(limits: limits, extra: parseExtra(root), fetchedAt: fetchedAt)
    }

    // MARK: - limits[]

    private static func parseLimit(_ entry: [String: Any]) -> UsageLimit? {
        guard let percent = number(entry["percent"]) ?? number(entry["utilization"]) else { return nil }
        let kind = entry["kind"] as? String ?? "limit"
        let group = entry["group"] as? String ?? ""
        let info = LimitNaming.describe(kind: kind, group: group, scope: scopeName(entry["scope"]))
        return UsageLimit(
            id: info.id, kind: kind, group: group.isEmpty ? inferredGroup(kind) : group,
            title: info.title, shortLabel: info.short, widgetTitle: info.widgetTitle,
            percent: percent, resetsAt: date(entry["resets_at"]), windowDuration: info.duration,
            serverSeverity: entry["severity"] as? String, isActive: entry["is_active"] as? Bool ?? false
        )
    }

    private static func scopeName(_ any: Any?) -> String? {
        if let string = any as? String { return string.isEmpty ? nil : string }
        guard let scope = any as? [String: Any] else { return nil }
        for key in ["model", "surface", "product", "feature"] {
            if let string = scope[key] as? String, !string.isEmpty { return string }
            if let nested = scope[key] as? [String: Any] {
                for nameKey in ["display_name", "name", "id"] {
                    if let name = nested[nameKey] as? String, !name.isEmpty { return name }
                }
            }
        }
        return scope["display_name"] as? String
    }

    private static func inferredGroup(_ kind: String) -> String {
        let k = kind.lowercased()
        if k.contains("session") || k.hasPrefix("five_hour") { return "session" }
        if k.contains("week") || k.hasPrefix("seven_day") { return "weekly" }
        return ""
    }

    // MARK: - legacy flat keys

    private static func parseLegacy(_ root: [String: Any]) -> [UsageLimit] {
        let keys = root.keys
            .filter { $0 == "five_hour" || $0.hasPrefix("seven_day") }
            .sorted { legacyOrder($0) < legacyOrder($1) }

        return keys.compactMap { key -> UsageLimit? in
            guard let entry = root[key] as? [String: Any],
                  let percent = number(entry["utilization"]) ?? number(entry["percent"])
            else { return nil }

            let kind: String, group: String, scope: String?
            switch key {
            case "five_hour": (kind, group, scope) = ("session", "session", nil)
            case "seven_day": (kind, group, scope) = ("weekly_all", "weekly", nil)
            default:
                (kind, group) = ("weekly_scoped", "weekly")
                scope = legacyScopeName(String(key.dropFirst("seven_day_".count)))
            }
            let info = LimitNaming.describe(kind: kind, group: group, scope: scope)
            return UsageLimit(
                id: info.id, kind: kind, group: group, title: info.title, shortLabel: info.short,
                widgetTitle: info.widgetTitle, percent: percent, resetsAt: date(entry["resets_at"]),
                windowDuration: info.duration, serverSeverity: nil, isActive: false
            )
        }
    }

    private static func legacyOrder(_ key: String) -> String {
        switch key {
        case "five_hour": return "0"
        case "seven_day": return "1"
        default: return "2" + key
        }
    }

    private static func legacyScopeName(_ raw: String) -> String {
        switch raw {
        case "oauth_apps": return "OAuth apps"
        default: return LimitNaming.humanize(raw)
        }
    }

    // MARK: - extra usage

    private static func parseExtra(_ root: [String: Any]) -> ExtraUsage? {
        if let spend = root["spend"] as? [String: Any], let used = money(spend["used"]) {
            let currency = (spend["used"] as? [String: Any])?["currency"] as? String ?? "USD"
            return ExtraUsage(used: used, limit: money(spend["limit"]), currency: currency,
                              enabled: spend["enabled"] as? Bool ?? false)
        }
        if let extra = root["extra_usage"] as? [String: Any] {
            let places = number(extra["decimal_places"]) ?? 2
            let scale = pow(10, places)
            return ExtraUsage(
                used: (number(extra["used_credits"]) ?? 0) / scale,
                limit: number(extra["monthly_limit"]).map { $0 / scale },
                currency: extra["currency"] as? String ?? "USD",
                enabled: extra["is_enabled"] as? Bool ?? false
            )
        }
        return nil
    }

    private static func money(_ any: Any?) -> Double? {
        guard let money = any as? [String: Any], let minor = number(money["amount_minor"]) else { return nil }
        return minor / pow(10, number(money["exponent"]) ?? 2)
    }

    // MARK: - primitives

    static func number(_ any: Any?) -> Double? {
        switch any {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ any: Any?) -> Date? {
        if let seconds = number(any) {
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        guard let string = any as? String, !string.isEmpty else { return nil }
        if let date = isoFractional.date(from: string) ?? isoPlain.date(from: string) { return date }
        // The API sends microseconds ("…:00.076612+00:00"); drop the fraction and retry.
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoPlain.date(from: trimmed)
    }
}

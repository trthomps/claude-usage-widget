import Foundation
import Security

/// Claude Code's OAuth login, read (never written) from where Claude Code keeps it.
struct OAuthCredential {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?
    var source: String

    var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
    var expiresSoon: Bool { expiresAt.map { $0 <= Date().addingTimeInterval(60) } ?? false }

    /// "Max · 20x", "Team · 5x", "Pro". Only a fallback: Claude Code writes these fields at
    /// login and never updates them, so they go stale after a plan change. See `PlanName.fromProfile`.
    var planDescription: String? { PlanName.describe(type: subscriptionType, tier: rateLimitTier) }
}

enum PlanName {
    static func describe(type: String?, tier: String?) -> String? {
        guard var raw = type?.lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("claude_") { raw.removeFirst("claude_".count) }
        let names = ["pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise", "free": "Free"]
        let base = names[raw] ?? raw.capitalized
        if let tier, let range = tier.range(of: #"\d+x"#, options: .regularExpression) {
            return "\(base) · \(tier[range])"
        }
        return base
    }

    /// The current plan from `GET /api/oauth/profile`: the server's display name ("Ultra")
    /// when it sends one, otherwise built from the organization type and rate-limit tier.
    static func fromProfile(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let org = root["organization"] as? [String: Any] else { return nil }
        if let name = (org["plan_display_name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return describe(type: org["organization_type"] as? String, tier: org["rate_limit_tier"] as? String)
    }
}

enum CredentialStore {
    static let keychainService = "Claude Code-credentials"

    /// Looks in the macOS Keychain first (where Claude Code stores its login on a Mac),
    /// then in `~/.claude/.credentials.json`.
    static func load() throws -> OAuthCredential {
        var keychainFailure: String?

        for service in candidateServices() {
            switch readKeychain(service: service) {
            case .success(let data):
                if let credential = parse(data, source: "Keychain · \(service)") { return credential }
            case .failure(let message):
                keychainFailure = keychainFailure ?? message
            case .notFound:
                continue
            }
        }

        for url in credentialFiles() {
            if let data = try? Data(contentsOf: url),
               let credential = parse(data, source: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                return credential
            }
        }

        if let keychainFailure { throw UsageError.keychain(keychainFailure) }
        throw UsageError.noCredentials
    }

    // MARK: - Keychain

    private enum KeychainRead {
        case success(Data)
        case notFound
        case failure(String)
    }

    /// The default service, plus suffixed variants Claude Code creates when
    /// `CLAUDE_CONFIG_DIR` is set, newest first.
    private static func candidateServices() -> [String] {
        var services = [keychainService]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            let others = items
                .compactMap { item -> (String, Date)? in
                    guard let service = item[kSecAttrService as String] as? String,
                          service.hasPrefix(keychainService), service != keychainService
                    else { return nil }
                    return (service, item[kSecAttrModificationDate as String] as? Date ?? .distantPast)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
            services.append(contentsOf: others)
        }
        return services
    }

    /// Reads through `/usr/bin/security`. Claude Code writes the item with that same tool,
    /// so the item's access list already trusts it and no Keychain prompt appears.
    private static func readKeychain(service: String) -> KeychainRead {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        switch process.terminationStatus {
        case 0:
            return .success(decodeSecurityOutput(output))
        case 44: // errSecItemNotFound
            return .notFound
        default:
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(message?.isEmpty == false ? message! : "security exited with \(process.terminationStatus)")
        }
    }

    /// `security -w` prints the secret as text, or as hex if it isn't printable.
    private static func decodeSecurityOutput(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") { return Data(text.utf8) }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if text.count % 2 == 0, text.unicodeScalars.allSatisfy(hexDigits.contains) {
            var bytes = [UInt8]()
            bytes.reserveCapacity(text.count / 2)
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                if let byte = UInt8(text[index..<next], radix: 16) { bytes.append(byte) }
                index = next
            }
            return Data(bytes)
        }
        return Data(text.utf8)
    }

    // MARK: - Files

    private static func credentialFiles() -> [URL] {
        var urls: [URL] = []
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            urls.append(URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json"))
        }
        urls.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json"))
        return urls
    }

    // MARK: - Parsing

    private static func parse(_ data: Data, source: String) -> OAuthCredential? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresAt = UsageParser.number(oauth["expiresAt"]).map {
            Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0)
        }
        return OAuthCredential(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String,
            source: source
        )
    }
}
